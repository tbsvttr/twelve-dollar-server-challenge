# frozen_string_literal: true

require_relative "http"
require_relative "epoll"

# The fallback connection layer, for kernels or sandboxes without io_uring. Idle keep-alive
# connections sit in a kernel epoll set (edge-triggered, so a connection is registered once and
# never re-armed). One Async task waits for that set to become readable through the reactor, and
# the worker fibers serve the connections that are ready. Each connection is a descriptor, so
# capacity is the process descriptor limit; past it, clients reconnect.
class EpollServer < HTTPServer
  READ_SIZE = 8192
  MAX_EVENTS = 1024

  def initialize(app, host, port)
    super(app, host, port, Process.getrlimit(:NOFILE).first)
  end

  def run(task)
    @task = task
    @epfd = Epoll.create
    @event = Epoll.event(Epoll::IN | Epoll::RDHUP | Epoll::ET)
    @sockets = [] # by descriptor
    @state = [] # by descriptor: IDLE, BUSY (queued or being served) or AGAIN (busy, and new data came)
    @partial = {} # descriptor => bytes of a request that hasn't fully arrived
    @ready = Thread::Queue.new
    WORKERS.times { add_worker }
    task.async { dispatch }
    task.async { accept_loop }
  end

  private

  def accept_loop
    loop do
      socket = @server.accept_nonblock(exception: false)
      if socket == :wait_readable
        @server.wait_readable
        next
      end
      @open += 1
      fd = socket.fileno
      @sockets[fd] = socket
      @state[fd] = IDLE
      Epoll.control(@epfd, Epoll::CTL_ADD, fd, @event)
    rescue Errno::EMFILE, Errno::ENFILE, Errno::ENOBUFS, Errno::ENOMEM
      sleep 0.01 # out of descriptors: let responses retire connections, then accept again
    rescue Errno::ECONNABORTED, Errno::EPROTO
      next
    end
  end

  IDLE = 0
  BUSY = 1
  AGAIN = 2

  # Waits (through the reactor) for the epoll set to have ready connections, then queues them.
  # A connection that is already queued or being served is only flagged, so one worker serves it
  # at a time (requests stay in order) and the worker reads it again before letting it go idle.
  def dispatch
    poller = IO.for_fd(@epfd, autoclose: false)
    events = Epoll.events(MAX_EVENTS)
    loop do
      poller.wait_readable
      Epoll.ready(@epfd, events, MAX_EVENTS) do |fd|
        case @state[fd]
        when IDLE
          @state[fd] = BUSY
          @ready.push(fd)
          add_worker if @waiting < @ready.size && @workers < MAX_WORKERS
        when BUSY
          @state[fd] = AGAIN
        end
      end
    end
  end

  def work
    io_buffer = IO::Buffer.new(READ_SIZE)
    loop do
      @waiting += 1
      fd = @ready.pop(false) # explicit: YJIT sends `pop` to the interpreter when its optional argument is left out
      @waiting -= 1
      service(fd, io_buffer)
    rescue StandardError => error
      Console.error(self, error)
    end
  end

  # Edge-triggered: a read shorter than READ_SIZE emptied the socket, and anything that arrives
  # after it raises a new edge, which `dispatch` turns into AGAIN while this worker still holds fd.
  #
  # The first read goes through the scheduler, so with io_uring the reads of every connection that
  # became ready in a reactor pass are submitted together. That read waits for data, so it is only
  # used where data is expected: a connection whose new data was already read in an earlier pass
  # (a stale edge) would hold this worker until its client sends again, which is why the pool can
  # grow. Re-reads after AGAIN, and reads past a full buffer, don't wait.
  def service(fd, io_buffer)
    socket = @sockets[fd] or return
    wait = true
    loop do
      @state[fd] = BUSY
      buffer = @partial.delete(fd)
      loop do
        data = if wait
                 wait = false
                 length = Fiber.scheduler.io_read(socket, io_buffer, 1, 0)
                 io_buffer.get_string(0, length) if length.positive?
               else
                 socket.read_nonblock(READ_SIZE, nil, exception: false)
               end
        break if data == :wait_readable
        return disconnect(fd, socket) unless data

        buffer = buffer ? buffer << data : data
        break if data.bytesize < READ_SIZE
      end

      if buffer
        rest = drain(socket, buffer) or return disconnect(fd, socket)
        @partial[fd] = rest unless rest.empty?
      end
      next if @state[fd] == AGAIN

      @state[fd] = IDLE
      return
    end
  rescue IOError, SystemCallError
    disconnect(fd, socket)
  end

  def disconnect(fd, socket)
    @sockets[fd] = nil
    @state[fd] = nil
    @partial.delete(fd)
    @open -= 1
    socket.close unless socket.closed?
  end

  # Through the fiber scheduler: with io_uring, every worker's write is queued and submitted together.
  # Straight to the scheduler rather than `socket.write`, which holds the socket's write lock while
  # the write is queued. Ruby keeps every mutex a thread holds in one linked list and walks it on
  # each unlock, so with thousands of writes in flight the unlocks alone took ~11% of the CPU.
  # The warm-up runs before the reactor starts, without a scheduler.
  def write(socket, data)
    scheduler = Fiber.scheduler or return socket.write(data)
    written = scheduler.io_write(socket, IO::Buffer.for(data), data.bytesize, 0)
    raise IOError, "write failed (#{-written})" if written.negative?
  end
end

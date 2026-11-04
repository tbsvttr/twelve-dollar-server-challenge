# frozen_string_literal: true

require_relative "http"
require_relative "ext/ring/cring"

# Client connections, their io_uring rings and HTTP framing are in C (ext/ring/ring.c); Ruby keeps
# the app. One Async task per ring waits for the ring's eventfd through the reactor and calls
# Cring::Server#process, which answers the GETs that can't suspend on the spot and returns the
# connections that need a worker fiber: writes, and reads while a write batch is open. Workers take
# those requests one at a time, run them through the app and hand the answers back to C.
#
# The HTTP parser in http.rb stays for the epoll fallback and for the warm-up, which runs requests
# through the app before the rings start; ring.c frames requests the same way, byte for byte.
class CringServer < HTTPServer
  RINGS = Integer(ENV.fetch("URING_RINGS", "4")) # each ring holds up to 65,535 connections
  BUFFERS = 4096 # receive buffers per ring
  BUFFER_SIZE = 2048
  LISTENERS = 8 # sockets on the port (SO_REUSEPORT), each with its own accept queue
  ACCEPTS = 2048 # accepts kept in flight, over the rings and the listeners
  REJECTS = [400, 411, 413, 431].to_h { |status| [status, %({"error":"#{REASONS[status].downcase}"})] }.freeze

  # Raises LoadError (no extension) or SystemCallError (io_uring unavailable or restricted) before
  # the listener is bound, so the caller can fall back to EpollServer.
  def initialize(app, host, port)
    slots = [Process.getrlimit(:NOFILE).first, 0xFFFF].min
    @cring = Cring::Server.new(RINGS, slots, BUFFERS, BUFFER_SIZE, 4096, 32_768)
    super(app, host, port, slots * RINGS)
  end

  def run(task)
    @task = task
    @ready = Thread::Queue.new
    @cring.start(@listeners.map(&:fileno), ACCEPTS, @app, KEEP, CLOSE, KEEP_10, REJECTS, @budget, @hard_budget, GET, POST, FEED)
    WORKERS.times { add_worker }
    RINGS.times { |index| task.async { pump(index) } }
  end

  private

  # LISTENERS sockets bound to the same port with SO_REUSEPORT: the kernel spreads new connections
  # over them, and each has its own accept queue of net.core.somaxconn entries. The first is the
  # one HTTPServer keeps.
  def listen(host, port)
    @listeners = Array.new(LISTENERS) do
      socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1)
      # Accepted sockets inherit TCP_NODELAY from the listener on Linux: no setsockopt per connection.
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      socket.bind(Addrinfo.tcp(host, port))
      socket.listen(65_535) # the kernel caps this at net.core.somaxconn
      socket
    end
    @listeners.first
  end

  # Waits (through the reactor) for the ring's eventfd, then handles every completion and hands the
  # resulting submissions to the kernel.
  def pump(index)
    eventfd = IO.for_fd(@cring.eventfd(index), autoclose: false)
    @cring.submit
    loop do
      eventfd.wait_readable
      if (ids = @cring.process(index, @app.writing?))
        i = 0
        while i < ids.size
          @ready.push(ids[i])
          add_worker if @waiting < @ready.size && @workers < MAX_WORKERS
          i += 1
        end
      end
      @cring.submit
    rescue StandardError => error
      Console.error(self, error)
    end
  end

  def work
    loop do
      @waiting += 1
      id = @ready.pop(false) # explicit: YJIT sends `pop` to the interpreter when its optional argument is left out
      @waiting -= 1
      serve(id)
      @cring.submit if @ready.empty?
    rescue StandardError => error
      Console.error(self, error)
    end
  end

  def serve(id)
    while (request = @cring.request(id))
      status, document = @app.call(request[0], request[1], request[2], request[3])
      @cring.respond(id, status, document)
    end
  rescue StandardError
    @cring.abandon(id)
    raise
  end

  # The warm-up writes to a socket pair.
  def write(socket, data)
    socket.write(data)
  end
end

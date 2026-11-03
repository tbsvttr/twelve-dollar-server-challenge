# frozen_string_literal: true

require_relative "http"
require_relative "uring"

# Client connections are io_uring direct descriptors (see uring.rb), so they don't count against the
# process descriptor limit: each ring holds up to RLIMIT_NOFILE of them, and there are RINGS rings.
# Every connection has one multishot receive armed for its lifetime, filled from the ring's provided
# buffers; one Async task per ring waits for the ring's eventfd through the reactor and turns
# completions into connection state. Worker fibers serve the connections that have new bytes, and
# their responses are queued as sends that the next submit hands to the kernel together. No
# connection waits in `accept` or reconnects for want of a descriptor: the process itself keeps
# about 15 descriptors open.
class UringServer < HTTPServer
  RINGS = Integer(ENV.fetch("URING_RINGS", "2"))
  SLOT_BITS = 16 # connection id = ring << SLOT_BITS | slot
  SLOT_MASK = (1 << SLOT_BITS) - 1
  BUFFERS = 4096 # provided receive buffers per ring
  BUFFER_SIZE = 2048
  SEND_SIZE = 8192 # pooled send buffers fit every response but an unusually large post or feed
  # user_data = connection id << 3 | operation
  ACCEPT = 0
  RECV = 1
  SEND = 2
  CANCEL = 3
  CLOSE_SLOT = 4
  ENOBUFS = 105
  ACCEPTS = 64 # accepts kept in flight, spread over the rings
  POST_REQUEST = "POST "

  # Raises LoadError (no liburing-ffi) or SystemCallError (io_uring unavailable or restricted)
  # before the listener is bound, so the caller can fall back to EpollServer.
  def initialize(app, host, port)
    slots = [Process.getrlimit(:NOFILE).first, SLOT_MASK].min
    @rings = Array.new(RINGS) do
      Uring::Ring.new(entries: 4096, completions: 32_768, slots: slots, buffers: BUFFERS, buffer_size: BUFFER_SIZE)
    end
    super(app, host, port, slots * RINGS)
  end

  def run(task)
    @task = task
    # By connection id:
    @input = [] # bytes received and not yet served
    @busy = [] # queued for or held by a worker
    @sending = [] # the send in flight (its memory), and its length and offset
    @send_length = []
    @send_offset = []
    @out = [] # responses waiting for the send in flight
    @send_pool = [] # free SEND_SIZE buffers
    @closing = [] # close once the sends are done
    @cancelled = [] # the receive was asked to end
    @dead = [] # the receive has ended
    @slots = @rings.first.slots
    @held = Array.new(RINGS, 0) # by ring: slots taken by connections and by accepts in flight
    @accepts = 0
    @ready = Thread::Queue.new
    WORKERS.times { add_worker }
    arm_accepts
    @rings.each_index { |index| task.async { pump(index) } }
  end

  private

  # Keeps ACCEPTS single-shot accepts in flight, each on the ring holding the fewest connections. With
  # a multishot accept per ring the kernel hands every connection to the first ring until its table
  # is full, and only then to the next.
  def arm_accepts
    while @accepts < ACCEPTS
      index = @held.index(@held.min)
      break if @held[index] >= @slots

      @held[index] += 1
      @accepts += 1
      @rings[index].accept(@server.fileno, (index << SLOT_BITS) << 3 | ACCEPT)
    end
  end

  # Waits (through the reactor) for the ring's eventfd, then handles every completion and hands the
  # resulting submissions to the kernel in one call.
  def pump(index)
    ring = @rings[index]
    eventfd = IO.for_fd(ring.eventfd, autoclose: false)
    ring.submit
    loop do
      eventfd.wait_readable
      eventfd.read_nonblock(8, nil, exception: false) # the explicit nil keeps YJIT compiling the call
      ring.each_completion { |data, result, flags| complete(ring, index, data >> 3, data & 7, result, flags) }
      flush # accepts are re-armed on whichever ring has room
    rescue StandardError => error
      Console.error(self, error)
    end
  end

  def complete(ring, index, id, operation, result, flags)
    case operation
    when RECV
      if result.positive?
        data = ring.take_buffer(flags >> Uring::CQE_BUFFER_SHIFT, result)
        if (input = @input[id]) then input << data else @input[id] = data end
        unless @busy[id]
          @busy[id] = true
          if reads_only?(@input[id])
            serve_inline(id)
          else
            @ready.push(id)
            add_worker if @waiting < @ready.size && @workers < MAX_WORKERS
          end
        end
        ring.receive(id & SLOT_MASK, id << 3 | RECV) if flags.nobits?(Uring::CQE_F_MORE)
      elsif result == -ENOBUFS # out of provided buffers: they come back with this pass's submit
        ring.receive(id & SLOT_MASK, id << 3 | RECV)
      else # end of stream, an error, or cancelled
        @dead[id] = true
        finish(id)
      end
    when SEND
      sent(id, result)
    when ACCEPT
      @accepts -= 1
      if result >= 0
        id = index << SLOT_BITS | result
        @open += 1
        ring.receive(result, id << 3 | RECV)
      else
        @held[index] -= 1
      end
      arm_accepts
    end
    # CANCEL and CLOSE_SLOT complete only when they fail: the receive ends or the slot is freed anyway.
  end

  # Only GETs, and no write batch open: serving them can't suspend, so the pump serves them itself
  # instead of handing the connection to a worker fiber (a queue push, and two fiber switches).
  def reads_only?(input)
    input.match?(GET_AT, 0) && !input.include?(POST_REQUEST) && !@app.writing?
  end

  # Inside the completion loop: an exception must not escape it, or completions already handled
  # would be handled again.
  def serve_inline(id)
    service(id)
  rescue StandardError => error
    Console.error(self, error)
  end

  def work
    loop do
      @waiting += 1
      id = @ready.pop(false) # explicit: YJIT sends `pop` to the interpreter when its optional argument is left out
      @waiting -= 1
      service(id)
      flush if @ready.empty?
    rescue StandardError => error
      Console.error(self, error)
    end
  end

  # Serves every complete request received on the connection, including bytes that arrive while it
  # is being served; a partial request stays in @input until the rest arrives.
  def service(id)
    while (buffer = @input[id])
      @input[id] = nil
      rest = drain(id, buffer) unless @closing[id]
      unless rest
        @closing[id] = true
        break
      end
      next if rest.empty?

      more = @input[id]
      @input[id] = more ? rest << more : rest
      break unless more
    end
    @busy[id] = false
    finish(id)
  rescue StandardError
    @busy[id] = false
    @closing[id] = true
    finish(id)
    raise
  end

  def flush
    @rings.each { |ring| ring.submit if ring.pending? }
  end

  # Moves the connection toward closing once nothing holds it: a closing connection's receive is
  # cancelled, and the slot of one whose receive has ended is freed.
  def finish(id)
    return if @busy[id] || @sending[id]

    if @dead[id]
      close_slot(id)
    elsif @closing[id] && !@cancelled[id]
      @cancelled[id] = true
      @rings[id >> SLOT_BITS].cancel(id << 3 | RECV, id << 3 | CANCEL)
    end
  end

  def close_slot(id)
    index = id >> SLOT_BITS
    @rings[index].close(id & SLOT_MASK, id << 3 | CLOSE_SLOT)
    @input[id] = @out[id] = nil
    @closing[id] = @cancelled[id] = @dead[id] = false
    @open -= 1
    @held[index] -= 1
    arm_accepts
  end

  # The response is copied out of Ruby strings, which the GC may move, into native memory that
  # stays put until the send completes: a pooled buffer, unless the response is larger.
  def send_now(id, data)
    length = data.bytesize
    memory = send_buffer(length)
    memory.put_bytes(0, data)
    start_send(id, memory, length)
  end

  def send_buffer(length)
    if length <= SEND_SIZE
      @send_pool.pop || FFI::MemoryPointer.new(:char, SEND_SIZE, false)
    else
      FFI::MemoryPointer.new(:char, length, false)
    end
  end

  def start_send(id, memory, length)
    @sending[id] = memory
    @send_length[id] = length
    @send_offset[id] = 0
    @rings[id >> SLOT_BITS].send_data(id & SLOT_MASK, memory, length, id << 3 | SEND)
  end

  def sent(id, result)
    memory = @sending[id]
    if result.negative?
      release(memory)
      @sending[id] = @out[id] = nil
      @closing[id] = true
      return finish(id)
    end

    offset = @send_offset[id] + result
    if offset < @send_length[id] # a short send: the rest goes next
      @send_offset[id] = offset
      @rings[id >> SLOT_BITS].send_data(id & SLOT_MASK, memory + offset, @send_length[id] - offset, id << 3 | SEND)
    elsif (pending = @out[id])
      @out[id] = nil
      release(memory)
      send_now(id, pending)
    else
      release(memory)
      @sending[id] = nil
      finish(id)
    end
  end

  def release(memory)
    @send_pool.push(memory) if memory.size == SEND_SIZE
  end

  # Responses on one connection go out in order: while a send is in flight, later ones wait in @out.
  # The warm-up writes to a socket pair instead.
  def write(id, data)
    return id.write(data) unless id.is_a?(Integer)

    if @sending[id]
      if (pending = @out[id]) then pending << data else @out[id] = data end
    else
      send_now(id, data)
    end
  end

  # The usual case, nothing in flight: the parts go straight into the send buffer, with no response
  # string built in between.
  def write_response(id, head, length, document)
    return super if !id.is_a?(Integer) || @sending[id]

    size = head.bytesize + length.bytesize + END_HEAD.bytesize + document.bytesize
    memory = send_buffer(size)
    memory.put_bytes(0, head)
    offset = head.bytesize
    memory.put_bytes(offset, length)
    offset += length.bytesize
    memory.put_bytes(offset, END_HEAD)
    memory.put_bytes(offset + END_HEAD.bytesize, document)
    start_send(id, memory, size)
  end
end

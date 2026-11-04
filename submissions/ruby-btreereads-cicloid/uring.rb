# frozen_string_literal: true

require "ffi"

# Just enough of io_uring(7) to own client connections as direct descriptors: slots in a ring's
# registered-file table rather than entries in the process descriptor table, so they don't count
# against RLIMIT_NOFILE. A ring holds at most RLIMIT_NOFILE slots, and every ring has its own table.
# liburing (liburing-ffi, through FFI) sets the rings up and enters the kernel.
module Uring
  extend FFI::Library

  ffi_lib "liburing-ffi.so.2"
  attach_function :io_uring_queue_init_params, %i[uint pointer pointer], :int
  attach_function :io_uring_register_files_sparse, %i[pointer uint], :int
  attach_function :io_uring_register_eventfd, %i[pointer int], :int
  attach_function :io_uring_submit, %i[pointer], :int
  attach_function :io_uring_peek_batch_cqe, %i[pointer pointer uint], :uint
  attach_function :io_uring_register_buf_ring, %i[pointer pointer uint], :int

  module LibC
    extend FFI::Library

    ffi_lib FFI::Library::LIBC
    attach_function :eventfd, %i[uint int], :int
    attach_function :posix_memalign, %i[pointer size_t size_t], :int
  end

  SETUP_CQSIZE = 1 << 3
  SETUP_SUBMIT_ALL = 1 << 7
  SETUP_SINGLE_ISSUER = 1 << 12
  FILE_INDEX_ALLOC = 0xFFFFFFFF # accept into any free slot of the ring's table
  SQE_FIXED_FILE = 1 << 0
  SQE_BUFFER_SELECT = 1 << 5
  SQE_CQE_SKIP_SUCCESS = 1 << 6
  RECV_MULTISHOT = 1 << 1 # in ioprio
  SQ_CQ_OVERFLOW = 1 << 1 # in the submission queue's kernel flags
  CQE_F_MORE = 1 << 1
  CQE_BUFFER_SHIFT = 16
  BATCH = 256
  EINVAL = 22
  BUF_REG_SIZE = 40 # struct io_uring_buf_reg
  PARAMS_SIZE = 120 # struct io_uring_params
  RING_SIZE = 512 # struct io_uring is 216 bytes in liburing 2.5; room to spare
  EFD_NONBLOCK = 0o4000
  EFD_CLOEXEC = 0o2000000
  # Opcodes, from enum io_uring_op
  OP_ACCEPT = 13
  OP_ASYNC_CANCEL = 14
  OP_CLOSE = 19
  OP_SEND = 26
  OP_RECV = 27
  # Offsets in liburing 2.5's struct io_uring: the kernel's ring pointers and liburing's own tail
  SQ_KHEAD = 0
  SQ_KFLAGS = 32
  SQ_SQES = 56
  SQ_SQE_TAIL = 68
  SQ_RING_MASK = 88
  SQ_RING_ENTRIES = 92
  CQ_KHEAD = 104
  CQ_KTAIL = 112
  CQ_CQES = 152
  CQ_RING_MASK = 176
  BLANK_SQE = ("\0" * 64).freeze
  U32 = 0xFFFFFFFF

  # One ring: its submission/completion queues, a sparse table of `slots` direct descriptors,
  # `buffers` provided receive buffers of `buffer_size` bytes, and an eventfd the kernel signals on
  # every completion, which the reactor can wait on like any other descriptor. The buffers sit in a
  # buffer ring (IORING_REGISTER_PBUF_RING) shared with the kernel: giving one back is a ring entry
  # and a tail store, with no submission.
  #
  # liburing sets the ring up and enters the kernel; Ruby writes submissions and reads completions
  # straight from the ring's shared memory, the way liburing's inline helpers do, with no FFI call
  # per entry.
  class Ring
    attr_reader :eventfd, :slots

    def initialize(entries:, completions:, slots:, buffers:, buffer_size:, group: 0)
      @ring = FFI::MemoryPointer.new(RING_SIZE)
      params = FFI::MemoryPointer.new(PARAMS_SIZE)
      params.put_uint32(4, completions)
      params.put_uint32(8, SETUP_CQSIZE | SETUP_SUBMIT_ALL | SETUP_SINGLE_ISSUER)
      check("io_uring_queue_init", Uring.io_uring_queue_init_params(entries, @ring, params))
      check("io_uring_register_files_sparse", Uring.io_uring_register_files_sparse(@ring, slots))
      @slots = slots
      @eventfd = LibC.eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)
      raise SystemCallError.new("eventfd", FFI.errno) if @eventfd.negative?

      check("io_uring_register_eventfd", Uring.io_uring_register_eventfd(@ring, @eventfd))

      @sq_head = @ring.get_pointer(SQ_KHEAD)
      @sq_flags = @ring.get_pointer(SQ_KFLAGS)
      @sqes = @ring.get_pointer(SQ_SQES)
      @sqe_tail = @ring.get_uint32(SQ_SQE_TAIL)
      @sq_mask = @ring.get_uint32(SQ_RING_MASK)
      @sq_entries = @ring.get_uint32(SQ_RING_ENTRIES)
      @cq_head = @ring.get_pointer(CQ_KHEAD)
      @cq_tail = @ring.get_pointer(CQ_KTAIL)
      @cqes = @ring.get_pointer(CQ_CQES)
      @cq_mask = @ring.get_uint32(CQ_RING_MASK)

      @batch = FFI::MemoryPointer.new(:pointer, BATCH)
      @pending = 0
      @group = group
      @buffer_size = buffer_size
      @memory = FFI::MemoryPointer.new(buffer_size, buffers)
      @base = @memory.address
      register_buffers(buffers)
    end

    # One connection, into a free slot of this ring's table.
    def accept(listener, data)
      put(OP_ACCEPT, listener, 0, 0, data, 0, 0, FILE_INDEX_ALLOC)
    end

    def receive(slot, data)
      put(OP_RECV | (SQE_FIXED_FILE | SQE_BUFFER_SELECT) << 8 | RECV_MULTISHOT << 16, slot, 0, 0, data, 0, @group)
    end

    def send_data(slot, address, length, data)
      put(OP_SEND | SQE_FIXED_FILE << 8, slot, address, length, data)
    end

    # Ends the request whose user_data is `target` (a multishot receive); only failures complete.
    def cancel(target, data)
      put(OP_ASYNC_CANCEL | SQE_CQE_SKIP_SUCCESS << 8, -1, target, 0, data)
    end

    # Frees the slot; only failures complete.
    def close(slot, data)
      put(OP_CLOSE | SQE_CQE_SKIP_SUCCESS << 8, 0, 0, 0, data, 0, 0, slot + 1)
    end

    # The bytes a receive completion put in buffer `id`. The buffer goes straight back to the
    # kernel, once its bytes are copied out.
    def take_buffer(id, length)
      data = @memory.get_bytes(id * @buffer_size, length)
      give_buffer(id)
      @buffer_ring.put_uint16(14, @buffer_tail) # the ring's tail shares entry 0 with its reserved field
      data
    end

    def submit
      enter unless @pending.zero?
    end

    def pending?
      @pending > 0
    end

    # Yields user_data, res and flags of every completion that is ready, without blocking.
    def each_completion
      cqes = @cqes
      head = @cq_head.get_uint32(0)
      flushed = false
      while true # not `loop`: leaving it with `break` would throw
        tail = @cq_tail.get_uint32(0)
        if head == tail
          # Completions the ring had no room for wait in the kernel; liburing's peek moves them in.
          break if flushed || @sq_flags.get_uint32(0) & SQ_CQ_OVERFLOW == 0

          flushed = true
          Uring.io_uring_peek_batch_cqe(@ring, @batch, BATCH)
          next
        end

        while head != tail
          entry = (head & @cq_mask) << 4
          yield cqes.get_uint64(entry), cqes.get_int32(entry + 8), cqes.get_uint32(entry + 12)
          head = (head + 1) & U32
        end
        @cq_head.put_uint32(0, head)
      end
    end

    private

    # Writes the next submission queue entry in place, every field as io_uring_prep_rw leaves it.
    # `head` is the first word: opcode, flags << 8, ioprio << 16.
    def put(head, fd, address, length, data, offset = 0, group = 0, file_index = 0)
      tail = @sqe_tail
      enter if ((tail - @sq_head.get_uint32(0)) & U32) >= @sq_entries # full: hand it to the kernel first
      sqes = @sqes
      entry = (tail & @sq_mask) << 6
      sqes.put_bytes(entry, BLANK_SQE)
      sqes.put_uint32(entry, head)
      sqes.put_int32(entry + 4, fd)
      sqes.put_uint64(entry + 8, offset) unless offset.zero?
      sqes.put_uint64(entry + 16, address) unless address.zero?
      sqes.put_uint32(entry + 24, length) unless length.zero?
      sqes.put_uint64(entry + 32, data)
      sqes.put_uint16(entry + 40, group) unless group.zero?
      sqes.put_uint32(entry + 44, file_index) unless file_index.zero?
      @sqe_tail = (tail + 1) & U32
      @pending += 1
    end

    # liburing publishes the tail it keeps in struct io_uring, so it gets ours first.
    def enter
      @ring.put_uint32(SQ_SQE_TAIL, @sqe_tail)
      @pending = 0
      check("io_uring_submit", Uring.io_uring_submit(@ring))
    end

    # Ubuntu's 6.8.0-136+ kernels reject the registration unless a reserved field is set
    # (Launchpad #2162843), so a refusal is retried with it.
    def register_buffers(count)
      memory = FFI::MemoryPointer.new(:pointer)
      check("posix_memalign", -LibC.posix_memalign(memory, 4096, count * 16))
      @buffer_ring = FFI::Pointer.new(memory.read_pointer.address)
      @buffer_ring.put_bytes(0, BLANK_SQE * (count / 4)) # count * 16 zero bytes
      @buffer_mask = count - 1
      @buffer_tail = 0
      registration = FFI::MemoryPointer.new(BUF_REG_SIZE)
      registration.put_uint64(0, @buffer_ring.address)
      registration.put_uint32(8, count)
      registration.put_uint16(12, @group)
      result = Uring.io_uring_register_buf_ring(@ring, registration, 0)
      if result == -EINVAL
        registration.put_uint64(16, 1)
        result = Uring.io_uring_register_buf_ring(@ring, registration, 0)
      end
      check("io_uring_register_buf_ring", result)
      count.times { |id| give_buffer(id) }
      @buffer_ring.put_uint16(14, @buffer_tail)
    end

    # struct io_uring_buf: addr u64, len u32, bid u16
    def give_buffer(id)
      entry = (@buffer_tail & @buffer_mask) << 4
      @buffer_ring.put_uint64(entry, @base + id * @buffer_size)
      @buffer_ring.put_uint32(entry + 8, @buffer_size)
      @buffer_ring.put_uint16(entry + 12, id)
      @buffer_tail = (@buffer_tail + 1) & 0xFFFF
    end

    def check(call, result)
      raise SystemCallError.new(call, -result) if result.negative?

      result
    end
  end
end

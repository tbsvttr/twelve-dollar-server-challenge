# frozen_string_literal: true

require "ffi"

# Just enough of io_uring(7), bound from liburing-ffi (liburing's inline helpers, exported) through
# FFI, to own client connections as direct descriptors: slots in a ring's registered-file table
# rather than entries in the process descriptor table, so they don't count against RLIMIT_NOFILE.
# A ring holds at most RLIMIT_NOFILE slots, and every ring has its own table.
module Uring
  extend FFI::Library

  ffi_lib "liburing-ffi.so.2"
  attach_function :io_uring_queue_init_params, %i[uint pointer pointer], :int
  attach_function :io_uring_register_files_sparse, %i[pointer uint], :int
  attach_function :io_uring_register_eventfd, %i[pointer int], :int
  attach_function :io_uring_prep_provide_buffers, %i[pointer pointer int int int int], :void
  attach_function :io_uring_get_sqe, %i[pointer], :pointer
  attach_function :io_uring_prep_accept_direct, %i[pointer int pointer pointer int uint], :void
  attach_function :io_uring_prep_recv_multishot, %i[pointer int pointer size_t int], :void
  attach_function :io_uring_prep_send, %i[pointer int pointer size_t int], :void
  attach_function :io_uring_prep_cancel64, %i[pointer uint64 int], :void
  attach_function :io_uring_prep_close_direct, %i[pointer uint], :void
  attach_function :io_uring_sqe_set_data64, %i[pointer uint64], :void
  attach_function :io_uring_sqe_set_flags, %i[pointer uint], :void
  attach_function :io_uring_submit, %i[pointer], :int
  attach_function :io_uring_peek_batch_cqe, %i[pointer pointer uint], :uint
  attach_function :io_uring_cq_advance, %i[pointer uint], :void

  module LibC
    extend FFI::Library

    ffi_lib FFI::Library::LIBC
    attach_function :eventfd, %i[uint int], :int
  end

  SETUP_CQSIZE = 1 << 3
  SETUP_SUBMIT_ALL = 1 << 7
  SETUP_SINGLE_ISSUER = 1 << 12
  FILE_INDEX_ALLOC = 0xFFFFFFFF # accept into any free slot of the ring's table
  SQE_FIXED_FILE = 1 << 0
  SQE_BUFFER_SELECT = 1 << 5
  SQE_CQE_SKIP_SUCCESS = 1 << 6
  CQE_F_MORE = 1 << 1
  CQE_BUFFER_SHIFT = 16
  SQE_BUF_GROUP = 40 # offset of buf_group in struct io_uring_sqe
  CQE_SIZE = 16 # struct io_uring_cqe: user_data u64, res s32, flags u32
  BATCH = 256
  PROVIDE = (1 << 64) - 1 # user_data of buffer returns, which complete only when they fail
  PARAMS_SIZE = 120 # struct io_uring_params
  RING_SIZE = 512 # struct io_uring is 216 bytes in liburing 2.5; room to spare
  EFD_NONBLOCK = 0o4000
  EFD_CLOEXEC = 0o2000000

  # One ring: its submission/completion queues, a sparse table of `slots` direct descriptors,
  # `buffers` provided receive buffers of `buffer_size` bytes, and an eventfd the kernel signals on
  # every completion, which the reactor can wait on like any other descriptor. The buffers are the
  # classic provided-buffer group: Ubuntu's 6.8 kernel rejects registering a buffer ring
  # (IORING_REGISTER_PBUF_RING) with EINVAL, even one the kernel allocates.
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

      @batch = FFI::MemoryPointer.new(:pointer, BATCH)
      @pending = 0
      @group = group
      @buffer_size = buffer_size
      @memory = FFI::MemoryPointer.new(buffer_size, buffers)
      @addresses = Array.new(buffers) { |id| @memory + id * buffer_size }
      provide(@memory, buffers, 0)
      submit
    end

    # One connection, into a free slot of this ring's table.
    def accept(listener, data)
      sqe = take
      Uring.io_uring_prep_accept_direct(sqe, listener, nil, nil, 0, FILE_INDEX_ALLOC)
      Uring.io_uring_sqe_set_data64(sqe, data)
    end

    def receive(slot, data)
      sqe = take
      Uring.io_uring_prep_recv_multishot(sqe, slot, nil, 0, 0)
      Uring.io_uring_sqe_set_flags(sqe, SQE_FIXED_FILE | SQE_BUFFER_SELECT)
      sqe.put_uint16(SQE_BUF_GROUP, @group)
      Uring.io_uring_sqe_set_data64(sqe, data)
    end

    def send_data(slot, pointer, length, data)
      sqe = take
      Uring.io_uring_prep_send(sqe, slot, pointer, length, 0)
      Uring.io_uring_sqe_set_flags(sqe, SQE_FIXED_FILE)
      Uring.io_uring_sqe_set_data64(sqe, data)
    end

    # Ends the request whose user_data is `target` (a multishot receive); only failures complete.
    def cancel(target, data)
      sqe = take
      Uring.io_uring_prep_cancel64(sqe, target, 0)
      Uring.io_uring_sqe_set_flags(sqe, SQE_CQE_SKIP_SUCCESS)
      Uring.io_uring_sqe_set_data64(sqe, data)
    end

    # Frees the slot; only failures complete.
    def close(slot, data)
      sqe = take
      Uring.io_uring_prep_close_direct(sqe, slot)
      Uring.io_uring_sqe_set_flags(sqe, SQE_CQE_SKIP_SUCCESS)
      Uring.io_uring_sqe_set_data64(sqe, data)
    end

    # The bytes a receive completion put in provided buffer `id`; the buffer goes back to the kernel
    # with the next `submit`.
    def take_buffer(id, length)
      address = @addresses[id]
      data = address.get_bytes(0, length)
      provide(address, 1, id)
      data
    end

    def submit
      return if @pending.zero?

      @pending = 0
      check("io_uring_submit", Uring.io_uring_submit(@ring))
    end

    def pending?
      @pending.positive?
    end

    # Yields user_data, res and flags of every completion that is ready, without blocking.
    def each_completion
      loop do
        count = Uring.io_uring_peek_batch_cqe(@ring, @batch, BATCH)
        break if count.zero?

        index = 0
        while index < count
          cqe = @batch.get_pointer(index * FFI::Pointer.size)
          yield cqe.get_uint64(0), cqe.get_int32(8), cqe.get_uint32(12)
          index += 1
        end
        Uring.io_uring_cq_advance(@ring, count)
      end
    end

    private

    def provide(address, count, id)
      sqe = take
      Uring.io_uring_prep_provide_buffers(sqe, address, @buffer_size, count, @group, id)
      Uring.io_uring_sqe_set_flags(sqe, SQE_CQE_SKIP_SUCCESS)
      Uring.io_uring_sqe_set_data64(sqe, PROVIDE)
    end

    def take
      sqe = Uring.io_uring_get_sqe(@ring)
      if sqe.null? # the submission queue is full: hand it to the kernel and take a fresh entry
        submit_now
        sqe = Uring.io_uring_get_sqe(@ring)
      end
      @pending += 1
      sqe
    end

    def submit_now
      @pending = 0
      check("io_uring_submit", Uring.io_uring_submit(@ring))
    end

    def check(call, result)
      raise SystemCallError.new(call, -result) if result.negative?

      result
    end
  end
end

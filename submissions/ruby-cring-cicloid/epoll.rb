# frozen_string_literal: true

require "ffi"

# Just enough of Linux epoll(7), bound from libc through FFI, to park idle connections in the kernel.
module Epoll
  extend FFI::Library

  ffi_lib FFI::Library::LIBC
  attach_function :epoll_create1, [:int], :int
  attach_function :epoll_ctl, %i[int int int pointer], :int
  attach_function :epoll_wait, %i[int pointer int int], :int

  CTL_ADD = 1
  CTL_MOD = 3
  IN = 0x001
  RDHUP = 0x2000
  ONESHOT = 1 << 30
  ET = 1 << 31
  CLOEXEC = 0o2000000
  # struct epoll_event is packed on x86_64 (12 bytes) and naturally aligned elsewhere (16 bytes).
  SIZE, DATA = RUBY_PLATFORM.start_with?("x86_64") ? [12, 4] : [16, 8]

  def self.create
    fd = epoll_create1(CLOEXEC)
    raise SystemCallError.new("epoll_create1", FFI.errno) if fd.negative?

    fd
  end

  def self.event(events)
    pointer = FFI::MemoryPointer.new(SIZE)
    pointer.put_uint32(0, events)
    pointer
  end

  def self.events(count)
    FFI::MemoryPointer.new(SIZE, count)
  end

  # Registers or re-arms `fd`; the event's data field carries the descriptor.
  def self.control(epfd, operation, fd, event)
    event.put_uint64(DATA, fd)
    return if epoll_ctl(epfd, operation, fd, event).zero?

    raise SystemCallError.new("epoll_ctl", FFI.errno)
  end

  # Yields each ready descriptor without blocking.
  def self.ready(epfd, events, count)
    ready = epoll_wait(epfd, events, count, 0)
    index = 0
    while index < ready
      yield events.get_uint64(index * SIZE + DATA)
      index += 1
    end
  end
end

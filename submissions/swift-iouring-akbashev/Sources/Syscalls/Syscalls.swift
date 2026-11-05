// The Linux calls Glibc's Swift module leaves out, declared in Swift with `@_extern(c)`. Each is the C function itself:
// a call is a direct call to it.
import Glibc

@_extern(c, "getrlimit") public func sys_getrlimit(_ resource: Int32, _ rlim: UnsafeMutableRawPointer) -> Int32
@_extern(c, "setrlimit") public func sys_setrlimit(_ resource: Int32, _ rlim: UnsafeRawPointer) -> Int32
@_extern(c, "socket") public func sys_socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32
@_extern(c, "setsockopt") public func sys_setsockopt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: UnsafeRawPointer, _ len: UInt32) -> Int32
@_extern(c, "bind") public func sys_bind(_ fd: Int32, _ addr: UnsafeRawPointer, _ len: UInt32) -> Int32
@_extern(c, "listen") public func sys_listen(_ fd: Int32, _ backlog: Int32) -> Int32
@_extern(c, "write") public func sys_write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int
@_extern(c, "eventfd") public func sys_eventfd(_ initval: UInt32, _ flags: Int32) -> Int32
@_extern(c, "read") public func sys_read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int
@_extern(c, "setpriority") public func sys_setpriority(_ which: Int32, _ who: UInt32, _ prio: Int32) -> Int32
@_extern(c, "gettid") public func sys_gettid() -> Int32
@_extern(c, "pthread_setname_np") public func sys_pthread_setname_np(_ thread: pthread_t, _ name: UnsafePointer<CChar>) -> Int32

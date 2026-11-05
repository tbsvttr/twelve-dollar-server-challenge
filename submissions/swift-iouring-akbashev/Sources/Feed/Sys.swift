// The Linux interface: the constants are the Linux ABI's; the calls Glibc's Swift module leaves out are declared in the
// Syscalls module.
import Glibc
import Syscalls

/// Thread-safe helpers, usable from any thread: nonisolated, unlike the rest of the server.
nonisolated enum Sys {
    static let RLIMIT_NOFILE: Int32 = 7
    static let AF_INET: Int32 = 2
    static let AF_INET6: Int32 = 10
    static let SOCK_STREAM: Int32 = 1
    static let SOCK_NONBLOCK: Int32 = 0o4000
    static let SOCK_CLOEXEC: Int32 = 0o2000000
    static let SOL_SOCKET: Int32 = 1
    static let SO_REUSEADDR: Int32 = 2
    static let SO_REUSEPORT: Int32 = 15
    static let IPPROTO_TCP: Int32 = 6
    static let TCP_NODELAY: Int32 = 1
    static let IPPROTO_IPV6: Int32 = 41
    static let IPV6_V6ONLY: Int32 = 26
    static let EINTR: Int32 = 4
    static let EFD_CLOEXEC: Int32 = 0o2000000

}

nonisolated extension Sys {
    struct RLimit {
        var cur: UInt64 = 0
        var max: UInt64 = 0
    }

    /// Monotonic time in nanoseconds.
    @inline(__always) static func monotonicNanos() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    /// Seconds since the Unix epoch, as a Double.
    @inline(__always) static func unixNowF64() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// Raises the descriptor soft limit to the hard one (the box's unit allows 8,388,608) and returns it.
    static func raiseNofileLimit() -> Int {
        var rl = RLimit()
        guard sys_getrlimit(RLIMIT_NOFILE, &rl) == 0 else { return 0 }
        if rl.cur < rl.max {
            var raised = RLimit(cur: rl.max, max: rl.max)
            if sys_setrlimit(RLIMIT_NOFILE, &raised) == 0 { rl.cur = rl.max }
        }
        return Int(rl.cur)
    }

    @inline(__always) private static func setIntOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) -> Int32 {
        var v = value
        return sys_setsockopt(fd, level, name, &v, 4)
    }

    /// A non-blocking listener on `host:port`.
    static func bindListener(host: String, port: UInt16) throws(SystemError) -> Int32 {
        var v4 = in_addr()
        var v6 = in6_addr()
        let isV4 = inet_pton(AF_INET, host, &v4) == 1
        guard isV4 || inet_pton(AF_INET6, host, &v6) == 1 else { throw SystemError("invalid HOST address \(host)", EINVAL) }
        let fd = sys_socket(isV4 ? AF_INET : AF_INET6, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0)
        guard fd >= 0 else { throw SystemError("socket") }
        for opt in [SO_REUSEADDR, SO_REUSEPORT] {
            guard setIntOption(fd, SOL_SOCKET, opt, 1) == 0 else { throw SystemError("setsockopt") }
        }
        // Accepted sockets inherit it (their direct descriptors can't be given socket options from here).
        _ = setIntOption(fd, IPPROTO_TCP, TCP_NODELAY, 1)
        let bound: Int32
        if isV4 {
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            sa.sin_addr = v4
            bound = sys_bind(fd, &sa, UInt32(MemoryLayout<sockaddr_in>.size))
        } else {
            guard setIntOption(fd, IPPROTO_IPV6, IPV6_V6ONLY, 0) == 0 else { throw SystemError("setsockopt") }
            var sa = sockaddr_in6()
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_port = port.bigEndian
            sa.sin6_addr = v6
            bound = sys_bind(fd, &sa, UInt32(MemoryLayout<sockaddr_in6>.size))
        }
        guard bound == 0 else { throw SystemError("bind \(host):\(port)") }
        guard sys_listen(fd, 65535) == 0 else { throw SystemError("listen") }
        return fd
    }

    /// A line on standard error.
    static func logLine(_ line: String) {
        var text = line + "\n"
        text.withUTF8 { _ = sys_write(2, $0.baseAddress, $0.count) }
    }

}

nonisolated struct SystemError: Error, CustomStringConvertible {
    let call: String
    let code: Int32
    init(_ call: String, _ code: Int32 = errno) {
        self.call = call
        self.code = code
    }
    var description: String { "\(call): \(String(cString: strerror(code)))" }
}

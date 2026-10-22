#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>

#include "app.hpp"
#include "db.hpp"
#include "jwt.hpp"
#include "server.hpp"

namespace {

int make_listener(const char *host, uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1 || bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0 || listen(fd, 4096) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

}

int main() {
    const char *path = std::getenv("SQLITE_PATH");
    const char *secret = std::getenv("JWT_SECRET");
    const char *host = std::getenv("HOST");
    const char *port = std::getenv("PORT");
    struct stat st{};
    if (!path || stat(path, &st) != 0) {
        std::fprintf(stderr, "SQLITE_PATH must name an existing database file (got %s)\n", path ? path : "nothing");
        return 1;
    }

    std::signal(SIGPIPE, SIG_IGN);
    rlimit lim{};
    getrlimit(RLIMIT_NOFILE, &lim);
    lim.rlim_cur = lim.rlim_max;
    setrlimit(RLIMIT_NOFILE, &lim);
    getrlimit(RLIMIT_NOFILE, &lim);

    srv::Db db;
    if (!db.open(path)) {
        std::fprintf(stderr, "cannot open database: %s\n", db.error());
        return 1;
    }
    srv::JwtVerifier jwt(secret ? secret : "");
    srv::App app(db, jwt);

    int listener = make_listener(host ? host : "0.0.0.0", static_cast<uint16_t>(port ? std::atoi(port) : 80));
    if (listener < 0) {
        std::perror("listen");
        return 1;
    }
    srv::Server server(app, db, listener, lim.rlim_cur);
    if (!server.init()) {
        std::fprintf(stderr, "cannot start: %s\n", server.error());
        return 1;
    }
    struct sigaction on_stop{};
    on_stop.sa_handler = [](int) { srv::Server::stop(); };
    sigaction(SIGTERM, &on_stop, nullptr);
    sigaction(SIGINT, &on_stop, nullptr);
    server.run();
}

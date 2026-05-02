// drogonR — small portability shim for the wakeup pipe.
//
// POSIX uses pipe(2) + fcntl(2) for non-blocking; Windows lacks both for
// arbitrary fds, so we emulate a self-pipe with a loopback TCP socketpair
// (the same trick libuv/asio use). Returned values are stored as int —
// Windows SOCKETs for our short-lived loopback pair always fit in a
// positive int range in practice. The pollfd we hand to later::later_fd
// gets the value cast back to its native type at the call site.
//
// Helpers: makeWakePipe(fds[2]) -> 0 on success, -1 on failure.
//          closeWakeFd(fd)
//          writeWakeByte(fd) — best-effort, retries on EINTR
//          drainWakeBytes(fd) — drains everything currently readable

#ifndef DROGONR_SOCKET_COMPAT_H_
#define DROGONR_SOCKET_COMPAT_H_

#ifdef _WIN32
  #ifndef _WIN32_WINNT
    #define _WIN32_WINNT 0x0600
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>
#else
  #include <fcntl.h>
  #include <unistd.h>
  #include <cerrno>
#endif

namespace drogonR {

inline int makeWakePipe(int fds[2]) {
#ifdef _WIN32
    // Loopback socketpair: listen on 127.0.0.1:0, connect from a second
    // socket, accept. Set both to non-blocking afterwards.
    SOCKET listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) return -1;

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = 0;

    if (::bind(listener, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        ::closesocket(listener);
        return -1;
    }
    int addrLen = sizeof(addr);
    if (::getsockname(listener, reinterpret_cast<sockaddr *>(&addr), &addrLen) != 0) {
        ::closesocket(listener);
        return -1;
    }
    if (::listen(listener, 1) != 0) {
        ::closesocket(listener);
        return -1;
    }

    SOCKET client = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (client == INVALID_SOCKET) {
        ::closesocket(listener);
        return -1;
    }
    if (::connect(client, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        ::closesocket(listener);
        ::closesocket(client);
        return -1;
    }

    SOCKET server = ::accept(listener, nullptr, nullptr);
    ::closesocket(listener);
    if (server == INVALID_SOCKET) {
        ::closesocket(client);
        return -1;
    }

    u_long nb = 1;
    ::ioctlsocket(server, FIONBIO, &nb);
    ::ioctlsocket(client, FIONBIO, &nb);

    // Disable Nagle so the wakeup byte is delivered immediately.
    BOOL one = TRUE;
    ::setsockopt(server, IPPROTO_TCP, TCP_NODELAY,
                 reinterpret_cast<const char *>(&one), sizeof(one));
    ::setsockopt(client, IPPROTO_TCP, TCP_NODELAY,
                 reinterpret_cast<const char *>(&one), sizeof(one));

    fds[0] = static_cast<int>(server);  // read end
    fds[1] = static_cast<int>(client);  // write end
    return 0;
#else
    if (::pipe(fds) != 0) return -1;
    ::fcntl(fds[0], F_SETFL, O_NONBLOCK);
    ::fcntl(fds[1], F_SETFL, O_NONBLOCK);
    return 0;
#endif
}

inline void closeWakeFd(int fd) {
    if (fd < 0) return;
#ifdef _WIN32
    ::closesocket(static_cast<SOCKET>(fd));
#else
    ::close(fd);
#endif
}

inline void writeWakeByte(int fd) {
    if (fd < 0) return;
    char b = 1;
#ifdef _WIN32
    // send() on a non-blocking socket; ignore would-block (the dispatcher
    // will see the queue on its next drain) and any other failure.
    ::send(static_cast<SOCKET>(fd), &b, 1, 0);
#else
    while (::write(fd, &b, 1) == -1 && errno == EINTR) { /* retry */ }
#endif
}

inline void drainWakeBytes(int fd) {
    if (fd < 0) return;
    char buf[64];
#ifdef _WIN32
    while (::recv(static_cast<SOCKET>(fd), buf, sizeof(buf), 0) > 0) { /* drain */ }
#else
    while (::read(fd, buf, sizeof(buf)) > 0) { /* drain */ }
#endif
}

} // namespace drogonR

#endif // DROGONR_SOCKET_COMPAT_H_

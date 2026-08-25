// Loaded into sherpa-onnx-offline-websocket-server via DYLD_INSERT_LIBRARIES.
// The server has no bind-address option and listens on every interface.
// This rewrites any wildcard bind (0.0.0.0 or ::) to the loopback address,
// so only this Mac can reach the transcription port.
//
// Built by build.sh into YTT.app/Contents/Resources/lib/libbindfix.dylib.

#include <sys/socket.h>
#include <netinet/in.h>
#include <string.h>

int ytt_bind(int fd, const struct sockaddr *addr, socklen_t len) {
    if (addr && addr->sa_family == AF_INET && len >= sizeof(struct sockaddr_in)) {
        struct sockaddr_in a;
        memcpy(&a, addr, sizeof a);
        if (a.sin_addr.s_addr == htonl(INADDR_ANY)) {
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            return bind(fd, (struct sockaddr *)&a, sizeof a);
        }
    } else if (addr && addr->sa_family == AF_INET6 && len >= sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 a;
        memcpy(&a, addr, sizeof a);
        if (memcmp(&a.sin6_addr, &in6addr_any, sizeof in6addr_any) == 0) {
            a.sin6_addr = in6addr_loopback;
            return bind(fd, (struct sockaddr *)&a, sizeof a);
        }
    }
    return bind(fd, addr, len);
}

// dyld interposition table: every call to bind() in the process goes to ytt_bind.
__attribute__((used, section("__DATA,__interpose")))
static struct { void *replacement; void *original; } interposers[] = {
    { (void *)ytt_bind, (void *)bind },
};

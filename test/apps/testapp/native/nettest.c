#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// resolve host and fetch path over HTTP
int main(int argc, char **argv) {
    const char *host = argc > 1 ? argv[1] : "rhizo-test.internal";
    const char *port = argc > 2 ? argv[2] : "80";
    const char *path = argc > 3 ? argv[3] : "/nettest";

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo *res = NULL;
    int rc = getaddrinfo(host, port, &hints, &res);
    if (rc != 0) {
        printf("RHIZO_NETTEST_FAIL getaddrinfo rc=%d (%s)\n", rc, gai_strerror(rc));
        return 1;
    }

    char ip[INET6_ADDRSTRLEN];
    if (res->ai_family == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)res->ai_addr;
        inet_ntop(AF_INET6, &sin6->sin6_addr, ip, sizeof(ip));
    } else {
        struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
        inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
    }
    printf("RHIZO_NETTEST_RESOLVED ip=%s family=%s\n", ip,
           res->ai_family == AF_INET6 ? "inet6" : "inet");
    fflush(stdout);

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        printf("RHIZO_NETTEST_FAIL socket errno=%d\n", errno);
        freeaddrinfo(res);
        return 1;
    }
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        printf("RHIZO_NETTEST_FAIL connect errno=%d\n", errno);
        close(fd);
        freeaddrinfo(res);
        return 1;
    }
    freeaddrinfo(res);

    char req[256];
    int n = snprintf(req, sizeof(req),
                      "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", path, host);
    if (write(fd, req, (size_t)n) != n) {
        printf("RHIZO_NETTEST_FAIL write errno=%d\n", errno);
        close(fd);
        return 1;
    }

    char buf[4096];
    int got = 0, r;
    while (got < (int)sizeof(buf) - 1 &&
           (r = (int)read(fd, buf + got, sizeof(buf) - 1 - (size_t)got)) > 0) {
        got += r;
    }
    buf[got] = 0;
    close(fd);

    if (got == 0) {
        printf("RHIZO_NETTEST_FAIL empty response\n");
        return 1;
    }

    int status = 0;
    sscanf(buf, "HTTP/1.%*d %d", &status);
    printf("RHIZO_NETTEST_HTTP_STATUS %d\n", status);

    char *body = strstr(buf, "\r\n\r\n");
    body = body ? body + 4 : buf;
    printf("RHIZO_NETTEST_BODY %s\n", body);

    if (status == 200 && strstr(body, "RHIZO-NET-OK")) {
        printf("RHIZO_NETTEST_OK\n");
        return 0;
    }
    printf("RHIZO_NETTEST_FAIL bad-response status=%d\n", status);
    return 1;
}

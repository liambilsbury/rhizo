#ifndef RHIZO_FUSE_WIRE_H
#define RHIZO_FUSE_WIRE_H

#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <sys/uio.h>
#include <unistd.h>

#include <linux/fuse.h>

// write bytes of an iovec array
static inline int writev_all(int fd, struct iovec *iov, int iovcnt)
{
	while (iovcnt > 0) {
		ssize_t r = writev(fd, iov, iovcnt);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
				poll(&pfd, 1, -1);
				continue;
			}
			return -1;
		}
		size_t done = (size_t)r;
		while (iovcnt > 0 && done >= iov->iov_len) {
			done -= iov->iov_len;
			iov++;
			iovcnt--;
		}
		if (iovcnt > 0 && done > 0) {
			iov->iov_base = (uint8_t *)iov->iov_base + done;
			iov->iov_len -= done;
		}
	}
	return 0;
}

// write the fuse reply to fd
static inline int fuse_wire_reply(int fd, uint64_t unique, int32_t error,
				  const struct iovec *data, int ndata)
{
	struct fuse_out_header oh;
	struct iovec iov[8];
	uint32_t len = sizeof(oh);

	if (ndata > 7) {
		errno = EINVAL;
		return -1;
	}
	for (int i = 0; i < ndata; i++) {
		iov[i + 1] = data[i];
		len += (uint32_t)data[i].iov_len;
	}
	oh.len = len;
	oh.error = error;
	oh.unique = unique;
	iov[0].iov_base = &oh;
	iov[0].iov_len = sizeof(oh);
	return writev_all(fd, iov, ndata + 1);
}

#endif

#include "rhizo/memfd_buffer.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>

static int failures = 0;

// print a check's result and count a failure
static void check(bool ok, const char* what, long got) {
  std::printf("%s %s (got %ld)\n", ok ? "ok  " : "FAIL", what, got);
  if (!ok) failures++;
}

// run the memfd buffer checks
int main() {
  check(rhizo::LinearStrideBytes(1920, 4) == 7680, "1920 RGBA pixels need 7680 bytes", rhizo::LinearStrideBytes(1920, 4));
  check(rhizo::LinearStrideBytes(1, 4) == 64, "a row is at least 64 bytes", rhizo::LinearStrideBytes(1, 4));
  check(rhizo::LinearStrideBytes(1081, 1) == 1088, "1081 bytes round up to 1088", rhizo::LinearStrideBytes(1081, 1));
  check(rhizo::LinearStrideBytes(16, 4) == 64, "16 RGBA pixels are already 64 bytes and stay 64", rhizo::LinearStrideBytes(16, 4));
  check(rhizo::LinearStrideBytes(1024, 1) == 1024, "1024 bytes are already aligned and stay 1024",
        rhizo::LinearStrideBytes(1024, 1));
  check(rhizo::LinearStrideBytes(INT32_MAX / 2, 4) < 0, "a width whose stride passes INT32_MAX is refused, not wrapped",
        rhizo::LinearStrideBytes(INT32_MAX / 2, 4));
  check(rhizo::LinearStrideBytes(INT32_MAX - 1, 1) < 0, "a stride that rounds up past INT32_MAX is refused",
        rhizo::LinearStrideBytes(INT32_MAX - 1, 1));
  check(rhizo::LinearStrideBytes(0, 4) < 0, "a zero width is refused", rhizo::LinearStrideBytes(0, 4));
  check(rhizo::LinearStrideBytes(-64, 4) < 0, "a negative width is refused", rhizo::LinearStrideBytes(-64, 4));
  check(rhizo::MemfdBufferBytes(3840, 1015) == 3840ull * 1016, "a 1015-row buffer holds 1016 rows, llvmpipe's 4-row blocks",
        static_cast<long>(rhizo::MemfdBufferBytes(3840, 1015)));
  check(rhizo::MemfdBufferBytes(3840, 1080) == 3840ull * 1080, "a 1080-row buffer holds exactly 1080 rows",
        static_cast<long>(rhizo::MemfdBufferBytes(3840, 1080)));
  check(rhizo::MemfdBufferBytes(64, 1) == 64ull * 4, "a 1-row buffer holds one 4-row block",
        static_cast<long>(rhizo::MemfdBufferBytes(64, 1)));
  check(rhizo::MemfdBufferBytes(64, 0) == 64ull * 4, "a 0-row request still gets one block",
        static_cast<long>(rhizo::MemfdBufferBytes(64, 0)));
  check(rhizo::MemfdYuv420Bytes(1920, 960, 1014) == 1920ull * 1014 + 960ull * 507 + 960ull * 508,
        "a 1014-row YUV 4:2:0 buffer ends with its last chroma plane's 4-row block",
        static_cast<long>(rhizo::MemfdYuv420Bytes(1920, 960, 1014)));
  check(rhizo::MemfdYuv420Bytes(1920, 960, 1080) == 1920ull * 1080 + 960ull * 540 * 2,
        "a 1080-row YUV 4:2:0 buffer is exactly its three planes",
        static_cast<long>(rhizo::MemfdYuv420Bytes(1920, 960, 1080)));
  check(rhizo::MemfdBufferFits(rhizo::MemfdBufferBytes(7680, 1080)), "a 1080p RGBA buffer fits", 1);
  check(rhizo::MemfdBufferFits(static_cast<uint64_t>(INT32_MAX)), "a buffer of exactly INT32_MAX bytes fits", 1);
  check(!rhizo::MemfdBufferFits(rhizo::MemfdBufferBytes(rhizo::LinearStrideBytes(65536, 4), 16384)),
        "a 4 GiB buffer is refused: a wl_shm pool's size is an int32", 0);
  check(!rhizo::MemfdBufferFits(0), "a zero-byte buffer does not fit", 0);
  int fd = rhizo::CreateBufferMemfd("test", 7680 * 16);
  check(fd >= 0, "a memfd is made", fd);
  check(lseek(fd, 0, SEEK_END) == 7680 * 16, "its size is the asked size", lseek(fd, 0, SEEK_END));
  int seals = fcntl(fd, F_GET_SEALS);
  check((seals & (F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL)) == (F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL),
        "it is sealed against growing, shrinking and new seals", seals);
  check(ftruncate(fd, 7680 * 32) != 0, "it cannot grow", 0);
  void* p = mmap(nullptr, 7680 * 16, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  check(p != MAP_FAILED, "it maps shared, as llvmpipe and the mapper map it", 0);
  if (p != MAP_FAILED) {
    static_cast<unsigned char*>(p)[0] = 0xab;
    unsigned char b = 0;
    if (pread(fd, &b, 1, 0) != 1) b = 0;
    check(b == 0xab, "a write through the map is in the file", b);
    munmap(p, 7680 * 16);
  }
  close(fd);
  check(rhizo::CreateBufferMemfd("zero", 0) < 0, "a zero-byte buffer is refused", rhizo::CreateBufferMemfd("zero", 0));
  int sealed = rhizo::CreateBufferMemfd("sealed", 4096);
  check(rhizo::ShmemImportAllowed(sealed, 4096), "the mapper imports an allocator memfd of its allocSize", sealed);
  check(!rhizo::ShmemImportAllowed(sealed, 8192), "the mapper refuses a sealed memfd shorter than allocSize", 0);
  check(!rhizo::ShmemImportAllowed(sealed, 0), "the mapper refuses a memfd whose handle says allocSize 0, which lock would map by stride", 0);
  int unsealed = memfd_create("unsealed", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  check(unsealed >= 0 && ftruncate(unsealed, 4096) == 0, "an unsealed 4096-byte memfd is made", unsealed);
  check(!rhizo::ShmemImportAllowed(unsealed, 4096), "the mapper refuses an unsealed memfd: it could shrink under a map", 0);
  int noSealing = memfd_create("no-sealing", MFD_CLOEXEC);
  check(noSealing >= 0 && ftruncate(noSealing, 4096) == 0, "a memfd without sealing is made", noSealing);
  check(!rhizo::ShmemImportAllowed(noSealing, 4096), "the mapper refuses a memfd that cannot be sealed", 0);
  int tmpfile = open("/dev/shm", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
  check(tmpfile >= 0 && ftruncate(tmpfile, 4096) == 0, "a 4096-byte /dev/shm O_TMPFILE is made", tmpfile);
  check(!rhizo::ShmemImportAllowed(tmpfile, 4096), "the mapper refuses a /dev/shm O_TMPFILE", 0);
  int pipes[2];
  if (pipe(pipes) != 0) return 1;
  check(rhizo::ShmemImportAllowed(pipes[0], 4096), "a fd that is not shmem, as a dmabuf is not, is left to the import", 0);
  close(sealed); close(unsealed); close(noSealing); close(tmpfile); close(pipes[0]); close(pipes[1]);
  return failures ? 1 : 0;
}

#include "shm_present.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <set>
#include <string>

static int failures = 0;

// print a check's result and count a failure
static void check(bool ok, const char* what, unsigned long got) {
  std::printf("%s %s (got 0x%lx)\n", ok ? "ok  " : "FAIL", what, got);
  if (!ok) failures++;
}

// run the wl_shm present checks
int main() {
  const uint32_t ARGB = 0x34325241, XRGB = 0x34325258, ABGR = 0x34324241, XBGR = 0x34324258, NV12 = 0x3231564e;
  check(rhizo::ShmFormatOf(ARGB) == 0, "ARGB8888 is wl_shm's enum 0", rhizo::ShmFormatOf(ARGB));
  check(rhizo::ShmFormatOf(XRGB) == 1, "XRGB8888 is wl_shm's enum 1", rhizo::ShmFormatOf(XRGB));
  check(rhizo::ShmFormatOf(ABGR) == ABGR, "other formats keep their fourcc", rhizo::ShmFormatOf(ABGR));
  check(rhizo::ShmCopyFormat(ABGR) == 0, "ABGR8888 copies to ARGB8888", rhizo::ShmCopyFormat(ABGR));
  check(rhizo::ShmCopyFormat(XBGR) == 1, "XBGR8888 copies to XRGB8888", rhizo::ShmCopyFormat(XBGR));
  check(rhizo::ShmCopyFormat(NV12) == 0xffffffffu, "NV12 has no copy", rhizo::ShmCopyFormat(NV12));
  const uint32_t RGB565 = 0x36314752;
  const std::set<uint32_t> base = {0, 1}, with565 = {0, 1, RGB565};
  check(rhizo::ShmPresentable(base, ABGR), "ABGR8888 is presentable through its copy",
        rhizo::ShmPresentable(base, ABGR));
  check(rhizo::ShmPresentable(std::set<uint32_t>{}, XRGB), "XRGB8888 is presentable through its copy",
        rhizo::ShmPresentable(std::set<uint32_t>{}, XRGB));
  check(!rhizo::ShmPresentable(base, RGB565), "RGB565 is not presentable when wl_shm lacks it",
        rhizo::ShmPresentable(base, RGB565));
  check(rhizo::ShmPresentable(with565, RGB565), "RGB565 is presentable when wl_shm has it",
        rhizo::ShmPresentable(with565, RGB565));
  check(!rhizo::ShmPresentable(base, NV12), "NV12 is not presentable when wl_shm lacks it",
        rhizo::ShmPresentable(base, NV12));
  const uint8_t src[2 * 8] = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0, 0, 0, 0, 0, 0, 0, 0};
  uint8_t dst[2 * 12] = {};
  rhizo::SwapRedBlue(src, 8, dst, 12, 2, 1);
  check(dst[0] == 0x33 && dst[1] == 0x22 && dst[2] == 0x11 && dst[3] == 0x44, "pixel 0 swaps red and blue", dst[0]);
  check(dst[4] == 0x77 && dst[5] == 0x66 && dst[6] == 0x55 && dst[7] == 0x88, "pixel 1 swaps red and blue", dst[4]);
  check(dst[8] == 0 && dst[11] == 0, "nothing past the row's width is written", dst[8]);
  check(std::string(rhizo::PresentPathsName(true, true)) == "zwp_linux_dmabuf_v1 and wl_shm",
        "both globals bound name both present paths", 0);
  check(std::string(rhizo::PresentPathsName(false, true)) == "wl_shm", "wl_shm alone names wl_shm", 0);
  check(std::string(rhizo::PresentPathsName(true, false)) == "zwp_linux_dmabuf_v1",
        "dmabuf alone names zwp_linux_dmabuf_v1", 0);
  const uint32_t BGR888 = 0x34324742;
  check(rhizo::ShmBytesPerPixel(ARGB) == 4 && rhizo::ShmBytesPerPixel(XBGR) == 4, "8888 formats are 4 bytes a pixel",
        rhizo::ShmBytesPerPixel(ARGB));
  check(rhizo::ShmBytesPerPixel(BGR888) == 3, "BGR888 is 3 bytes a pixel", rhizo::ShmBytesPerPixel(BGR888));
  check(rhizo::ShmBytesPerPixel(RGB565) == 2, "RGB565 is 2 bytes a pixel", rhizo::ShmBytesPerPixel(RGB565));
  check(rhizo::ShmBytesPerPixel(NV12) == 0, "a planar format has no pixel size", rhizo::ShmBytesPerPixel(NV12));
  check(rhizo::ShmZeroCopyFits(ARGB, 100, 10, 400, 4000), "a 100x10 ARGB frame, stride 400, in 4000 bytes goes zero-copy", 0);
  check(!rhizo::ShmZeroCopyFits(ARGB, 100, 10, 399, 4000), "a stride under width*4 bytes never goes zero-copy", 0);
  check(!rhizo::ShmZeroCopyFits(ARGB, 100, 10, 400, 3999), "a file short of stride*height never goes zero-copy", 0);
  check(!rhizo::ShmZeroCopyFits(RGB565, 100, 10, 100, 4000), "an RGB565 stride counting pixels, not bytes, never goes zero-copy", 0);
  check(rhizo::ShmZeroCopyFits(RGB565, 100, 10, 200, 2000), "an RGB565 frame whose stride holds its row goes zero-copy", 0);
  check(!rhizo::ShmZeroCopyFits(NV12, 100, 10, 400, 4000), "a format with no pixel size never goes zero-copy", 0);
  check(!rhizo::ShmZeroCopyFits(ARGB, 0, 10, 400, 4000), "an empty frame never goes zero-copy", 0);
  check(rhizo::ShmCopyFits(100, 10, 400, 4000), "the copy reads a 100x10 frame, stride 400, from 4000 bytes", 0);
  check(!rhizo::ShmCopyFits(100, 10, 399, 4000), "the copy refuses a stride under width*4 bytes", 0);
  check(!rhizo::ShmCopyFits(100, 10, 400, 3999), "the copy refuses a file short of what it reads", 0);
  int unsealed = memfd_create("unsealed", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  check(rhizo::IsShmemFile(unsealed), "an unsealed memfd is a shmem file", unsealed);
  check(!rhizo::ShmemSealedAgainstShrink(unsealed), "an unsealed memfd is not sealed against shrinking", 0);
  int tmpfile = open("/dev/shm", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
  check(tmpfile >= 0, "a /dev/shm O_TMPFILE opens", tmpfile);
  check(rhizo::IsShmemFile(tmpfile), "a /dev/shm O_TMPFILE is a shmem file", tmpfile);
  check(!rhizo::ShmemSealedAgainstShrink(tmpfile), "a /dev/shm O_TMPFILE is not sealed against shrinking", 0);
  int sealed = rhizo::CreateBufferMemfd("sealed", 4096);
  check(rhizo::ShmemSealedAgainstShrink(sealed), "an allocator memfd is sealed against shrinking", sealed);
  check(!rhizo::ShmSealsAllowZeroCopy(0x2), "SHRINK alone, with no SEAL, takes the copy: a write seal could still be added", 0x2);
  check(!rhizo::ShmSealsAllowZeroCopy(0xa), "SHRINK and WRITE take the copy: the compositor cannot map it writable", 0xa);
  check(!rhizo::ShmSealsAllowZeroCopy(0x12), "SHRINK and FUTURE_WRITE take the copy", 0x12);
  check(!rhizo::ShmSealsAllowZeroCopy(0x16), "SHRINK, GROW and FUTURE_WRITE take the copy", 0x16);
  check(!rhizo::ShmSealsAllowZeroCopy(0xf), "SEAL, SHRINK, GROW and WRITE take the copy", 0xf);
  check(rhizo::ShmSealsAllowZeroCopy(0x7), "SEAL, SHRINK and GROW, the allocator's set, go zero-copy", 0x7);
  check(!rhizo::ShmSealsAllowZeroCopy(-1), "a fd with no seals, not shmem, never goes zero-copy", 0);
  check(rhizo::SealsHoldSize(0x2) && !rhizo::SealsHoldSize(0x1) && !rhizo::SealsHoldSize(-1),
        "only a seal set with SHRINK holds a file at its size", 0);
  check(rhizo::ShmSealsAllowZeroCopy(fcntl(sealed, F_GET_SEALS)), "an allocator memfd goes zero-copy", 0);
  int writeSealed = memfd_create("write-sealed", MFD_CLOEXEC | MFD_ALLOW_SEALING);
  check(writeSealed >= 0 && ftruncate(writeSealed, 4096) == 0 &&
            fcntl(writeSealed, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL) == 0,
        "a memfd sealed SHRINK, GROW, WRITE and SEAL is made", writeSealed);
  check(rhizo::ShmemSealedAgainstShrink(writeSealed) && !rhizo::ShmSealsAllowZeroCopy(fcntl(writeSealed, F_GET_SEALS)),
        "a write-sealed memfd is presentable but only through the copy", 0);
  close(writeSealed);
  int p[2];
  if (pipe(p) != 0) return 1;
  check(!rhizo::IsShmemFile(p[0]), "a pipe is not a shmem file", p[0]);
  check(!rhizo::ShmemSealedAgainstShrink(p[0]), "a pipe is not sealed shmem", p[0]);
  close(unsealed); close(tmpfile); close(sealed); close(p[0]); close(p[1]);
  return failures ? 1 : 0;
}

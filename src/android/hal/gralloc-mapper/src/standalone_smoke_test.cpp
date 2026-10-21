#include <dlfcn.h>
#include <fcntl.h>
#include <gbm.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>

#include <android/hardware/graphics/mapper/IMapper.h>

// load the mapper and allocate a GBM buffer
int main() {
  void* h = dlopen("mapper.rhizo.so", RTLD_NOW);
  if (!h) {
    fprintf(stderr, "FAIL: dlopen mapper.rhizo.so: %s\n", dlerror());
    return 1;
  }
  auto loadFn = reinterpret_cast<AIMapper_Error (*)(AIMapper**)>(
      dlsym(h, "AIMapper_loadIMapper"));
  if (!loadFn) {
    fprintf(stderr, "FAIL: dlsym AIMapper_loadIMapper: %s\n", dlerror());
    return 1;
  }
  AIMapper* mapper = nullptr;
  AIMapper_Error err = loadFn(&mapper);
  if (err != AIMAPPER_ERROR_NONE || !mapper) {
    fprintf(stderr, "FAIL: AIMapper_loadIMapper err=%d\n", err);
    return 1;
  }
  if (mapper->version != AIMAPPER_VERSION_5) {
    fprintf(stderr, "FAIL: mapper version=%u expected 5\n", mapper->version);
    return 1;
  }
  printf("PASS: mapper loaded, version=%u\n", mapper->version);

  int fd = open("/dev/dri/renderD128", O_RDWR);
  if (fd < 0) {
    fprintf(stderr, "FAIL: open renderD128: %s\n", strerror(errno));
    return 1;
  }
  struct gbm_device* gbm = gbm_create_device(fd);
  if (!gbm) {
    fprintf(stderr, "FAIL: gbm_create_device\n");
    return 1;
  }
  struct gbm_bo* bo = gbm_bo_create(gbm, 1280, 800, GBM_FORMAT_ABGR8888,
                                     GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
  if (!bo) {
    fprintf(stderr, "FAIL: gbm_bo_create\n");
    return 1;
  }
  int boFd = gbm_bo_get_fd(bo);
  uint32_t stride = gbm_bo_get_stride(bo);
  uint32_t width = gbm_bo_get_width(bo);
  uint32_t height = gbm_bo_get_height(bo);
  printf("PASS: gbm_bo_create %ux%u stride=%u fd=%d\n", width, height, stride, boFd);
  if (boFd < 0 || width != 1280 || height != 800 || stride < 1280 * 4) {
    fprintf(stderr, "FAIL: unexpected bo properties\n");
    return 1;
  }

  close(boFd);
  printf("ALL SYSTEM TESTS PASSED\n");
  return 0;
}

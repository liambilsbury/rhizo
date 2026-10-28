#ifndef RHIZO_C2_AOSP_UI_HIDL_GRALLOC_STUB_H
#define RHIZO_C2_AOSP_UI_HIDL_GRALLOC_STUB_H

// stub libui's HIDL gralloc 2/3/4 backends

#include <string>

#include <ui/Gralloc.h>

#define RHIZO_HIDL_GRALLOC_STUB(N)                                                                        \
  namespace android {                                                                                     \
  class Gralloc##N##Mapper : public GrallocMapper {                                                       \
   public:                                                                                                \
    static void preload() {}                                                                              \
    Gralloc##N##Mapper() = default;                                                                       \
    bool isLoaded() const override { return false; }                                                      \
    status_t importBuffer(const native_handle_t*, buffer_handle_t*) const override { return NO_INIT; }    \
    void freeBuffer(buffer_handle_t) const override {}                                                    \
    status_t validateBufferSize(buffer_handle_t, uint32_t, uint32_t, android::PixelFormat, uint32_t,      \
                                uint64_t, uint32_t) const override {                                      \
      return NO_INIT;                                                                                     \
    }                                                                                                     \
    void getTransportSize(buffer_handle_t, uint32_t* fds, uint32_t* ints) const override {                \
      *fds = 0;                                                                                           \
      *ints = 0;                                                                                          \
    }                                                                                                     \
    status_t lock(buffer_handle_t, uint64_t, const Rect&, int, void**, int32_t*, int32_t*)                \
        const override {                                                                                  \
      return NO_INIT;                                                                                     \
    }                                                                                                     \
    status_t lock(buffer_handle_t, uint64_t, const Rect&, int, android_ycbcr*) const override {           \
      return NO_INIT;                                                                                     \
    }                                                                                                     \
    int unlock(buffer_handle_t) const override { return -1; }                                             \
  };                                                                                                      \
  class Gralloc##N##Allocator : public GrallocAllocator {                                                 \
   public:                                                                                                \
    explicit Gralloc##N##Allocator(const Gralloc##N##Mapper&) {}                                          \
    bool isLoaded() const override { return false; }                                                      \
    std::string dumpDebugInfo(bool) const override { return ""; }                                         \
    status_t allocate(std::string, uint32_t, uint32_t, PixelFormat, uint32_t, uint64_t, uint32_t*,        \
                      buffer_handle_t*, bool) const override {                                            \
      return NO_INIT;                                                                                     \
    }                                                                                                     \
  };                                                                                                      \
  }

#endif

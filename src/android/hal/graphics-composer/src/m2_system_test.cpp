#include <fcntl.h>
#include <sys/mman.h>
#include <sys/system_properties.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>

#include <android/binder_manager.h>
#include <android/binder_process.h>
#include "aidl/android/hardware/graphics/allocator/IAllocator.h"
#include "aidl/android/hardware/graphics/composer3/BnComposerCallback.h"
#include "aidl/android/hardware/graphics/composer3/IComposer.h"
#include "aidl/android/hardware/graphics/composer3/IComposerClient.h"
#include "rhizo/virtgpu_transfer.h"

using namespace aidl::android::hardware::graphics;
using ndk::ScopedAStatus;
using ndk::SpAIBinder;

namespace {
constexpr int32_t kWidth = 1280, kHeight = 800;

class TestCallback : public composer3::BnComposerCallback {
 public:
  // ignore a hotplug callback
  ScopedAStatus onHotplug(int64_t, bool) override { return ScopedAStatus::ok(); }
  // ignore a hotplug event callback
  ScopedAStatus onHotplugEvent(int64_t, common::DisplayHotplugEvent) override {
    return ScopedAStatus::ok();
  }
  // ignore a refresh callback
  ScopedAStatus onRefresh(int64_t) override { return ScopedAStatus::ok(); }
  // ignore a seamless-possible callback
  ScopedAStatus onSeamlessPossible(int64_t) override { return ScopedAStatus::ok(); }
  // ignore a vsync callback
  ScopedAStatus onVsync(int64_t, int64_t, int32_t) override { return ScopedAStatus::ok(); }
  // ignore a vsync period timing change
  ScopedAStatus onVsyncPeriodTimingChanged(int64_t, const composer3::VsyncPeriodChangeTimeline&) override {
    return ScopedAStatus::ok();
  }
  // ignore a vsync idle callback
  ScopedAStatus onVsyncIdle(int64_t) override { return ScopedAStatus::ok(); }
  // ignore a refresh rate debug callback
  ScopedAStatus onRefreshRateChangedDebug(const composer3::RefreshRateChangedDebugData&) override {
    return ScopedAStatus::ok();
  }
  // ignore an HDCP level change
  ScopedAStatus onHdcpLevelsChanged(int64_t, const ::aidl::android::hardware::drm::HdcpLevels&) override {
    return ScopedAStatus::ok();
  }
};

struct SurfaceFlingerPause {
  // stop surfaceflinger
  SurfaceFlingerPause() { __system_property_set("ctl.stop", "surfaceflinger"); }
  // start surfaceflinger again
  ~SurfaceFlingerPause() { __system_property_set("ctl.start", "surfaceflinger"); }
};

// allocate an RGBA client target buffer
bool AllocateBuffer(const std::shared_ptr<allocator::IAllocator>& alloc,
                     allocator::AllocationResult* out) {
  allocator::BufferDescriptorInfo desc;
  desc.width = kWidth;
  desc.height = kHeight;
  desc.layerCount = 1;
  desc.format = common::PixelFormat::RGBA_8888;
  desc.usage = static_cast<common::BufferUsage>(
      static_cast<int64_t>(common::BufferUsage::CPU_WRITE_OFTEN) |
      static_cast<int64_t>(common::BufferUsage::CPU_READ_OFTEN) |
      static_cast<int64_t>(common::BufferUsage::GPU_RENDER_TARGET) |
      static_cast<int64_t>(common::BufferUsage::COMPOSER_CLIENT_TARGET));
  auto st = alloc->allocate2(desc, 1, out);
  if (!st.isOk()) {
    fprintf(stderr, "FAIL: allocate2: %s\n", st.getDescription().c_str());
    return false;
  }
  return true;
}

}

// present a buffer and check the readback
int main() {
  ABinderProcess_setThreadPoolMaxThreadCount(2);
  ABinderProcess_startThreadPool();

  SpAIBinder allocBinder(AServiceManager_waitForService(
      "android.hardware.graphics.allocator.IAllocator/default"));
  if (!allocBinder.get()) {
    fprintf(stderr, "FAIL: could not reach IAllocator/default\n");
    return 1;
  }
  auto alloc = allocator::IAllocator::fromBinder(allocBinder);
  printf("PASS: connected to IAllocator/default\n");

  SpAIBinder composerBinder(AServiceManager_waitForService(
      "android.hardware.graphics.composer3.IComposer/default"));
  if (!composerBinder.get()) {
    fprintf(stderr, "FAIL: could not reach IComposer/default\n");
    return 1;
  }
  auto composer = composer3::IComposer::fromBinder(composerBinder);
  printf("PASS: connected to IComposer/default\n");

  SurfaceFlingerPause sfPause;
  std::shared_ptr<composer3::IComposerClient> client;
  bool gotClient = false;
  for (int i = 0; i < 20 && !gotClient; i++) {
    gotClient = composer->createClient(&client).isOk() && client;
    if (!gotClient) usleep(100 * 1000);
  }
  if (!gotClient) {
    fprintf(stderr, "FAIL: createClient\n");
    return 1;
  }
  printf("PASS: createClient\n");

  auto cb = ndk::SharedRefBase::make<TestCallback>();
  if (!client->registerCallback(cb).isOk()) {
    fprintf(stderr, "FAIL: registerCallback\n");
    return 1;
  }
  printf("PASS: registerCallback (hotplug delivered synchronously)\n");

  allocator::AllocationResult clientTargetAlloc, readbackAlloc;
  if (!AllocateBuffer(alloc, &clientTargetAlloc)) return 1;
  if (!AllocateBuffer(alloc, &readbackAlloc)) return 1;
  printf("PASS: allocated client-target + readback buffers, stride=%d/%d\n",
         clientTargetAlloc.stride, readbackAlloc.stride);

  int ctFd = clientTargetAlloc.buffers[0].fds[0].get();
  size_t ctSize = static_cast<size_t>(clientTargetAlloc.stride) * kHeight;
  void* ctMap = mmap(nullptr, ctSize, PROT_READ | PROT_WRITE, MAP_SHARED, ctFd, 0);
  if (ctMap == MAP_FAILED) {
    fprintf(stderr, "FAIL: mmap client target: %s\n", strerror(errno));
    return 1;
  }
  memset(ctMap, 0xAA, ctSize);
  munmap(ctMap, ctSize);
  if (!rhizo::VirtgpuTransferToHost(ctFd, kWidth, kHeight, clientTargetAlloc.stride)) {
    fprintf(stderr, "FAIL: VirtgpuTransferToHost(client target)\n");
    return 1;
  }
  printf("PASS: wrote known pattern (0xAA) into client-target buffer\n");

  auto presentClientTarget = [&]() -> ScopedAStatus {
    composer3::DisplayCommand cmd;
    cmd.display = 1;
    cmd.presentDisplay = true;
    composer3::ClientTarget ct;
    ct.buffer.slot = 0;
    ::aidl::android::hardware::common::NativeHandle ctNh;
    ctNh.fds.push_back(clientTargetAlloc.buffers[0].fds[0].dup());
    ctNh.ints = clientTargetAlloc.buffers[0].ints;
    ct.buffer.handle = std::move(ctNh);
    ct.buffer.fence = ndk::ScopedFileDescriptor(-1);
    ct.dataspace = common::Dataspace::UNKNOWN;
    ct.hdrSdrRatio = 1.0f;
    cmd.clientTarget = std::move(ct);
    std::vector<composer3::CommandResultPayload> results;
    std::vector<composer3::DisplayCommand> cmds;
    cmds.push_back(std::move(cmd));
    return client->executeCommands(cmds, &results);
  };

  if (!presentClientTarget().isOk()) {
    fprintf(stderr, "FAIL: executeCommands(first present)\n");
    return 1;
  }
  printf("PASS: executeCommands(first present)\n");

  ::aidl::android::hardware::common::NativeHandle readbackNh;
  readbackNh.fds.push_back(readbackAlloc.buffers[0].fds[0].dup());
  readbackNh.ints = readbackAlloc.buffers[0].ints;
  ndk::ScopedFileDescriptor noFence(-1);
  if (!client->setReadbackBuffer(1, readbackNh, noFence).isOk()) {
    fprintf(stderr, "FAIL: setReadbackBuffer\n");
    return 1;
  }
  printf("PASS: setReadbackBuffer\n");

  auto st = presentClientTarget();
  if (!st.isOk()) {
    fprintf(stderr, "FAIL: executeCommands(present): %s\n", st.getDescription().c_str());
    return 1;
  }
  printf("PASS: executeCommands(presentDisplay)\n");

  int rbFd = readbackAlloc.buffers[0].fds[0].get();
  size_t rbSize = static_cast<size_t>(readbackAlloc.stride) * kHeight;
  void* rbMap = mmap(nullptr, rbSize, PROT_READ, MAP_SHARED, rbFd, 0);
  if (rbMap == MAP_FAILED) {
    fprintf(stderr, "FAIL: mmap readback buffer: %s\n", strerror(errno));
    return 1;
  }
  const uint8_t* bytes = static_cast<const uint8_t*>(rbMap);
  bool allMatch = true;
  for (size_t i = 0; i < rbSize; i++) {
    if (bytes[i] != 0xAA) {
      allMatch = false;
      fprintf(stderr, "FAIL: readback byte %zu = 0x%02x, expected 0xAA\n", i, bytes[i]);
      break;
    }
  }
  munmap(rbMap, rbSize);

  if (!allMatch) {
    fprintf(stderr, "FAIL: M2 SYSTEM TEST FAILED -- readback content did not match\n");
    return 1;
  }
  printf("PASS: readback buffer content matches client-target pattern exactly\n");
  printf("M2 SYSTEM TEST PASSED: real dmabuf allocated, composited, and read back through composer3\n");
  return 0;
}

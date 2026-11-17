#pragma once

#include <drm/drm.h>
#include <drm/virtgpu_drm.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <cstdint>

namespace rhizo {

// print "virtgpu context_init unavailable (why)" to stderr from a static initializer
inline void NoteNoContextInit(const char* why) {
  static const bool logged = [&] {
    dprintf(2, "virtgpu context_init unavailable (%s)\n", why);
    return true;
  }();
  (void)logged;
}

// return whether drm_version.name for drmFd is "virtio_gpu"
inline bool IsVirtgpuNode(int drmFd) {
  char name[32] = {};
  struct drm_version ver {};
  ver.name = name;
  ver.name_len = sizeof(name) - 1;
  return ioctl(drmFd, DRM_IOCTL_VERSION, &ver) == 0 && strcmp(name, "virtio_gpu") == 0;
}

// return whether /dev/dri/renderD128 is virtio_gpu or fails to open with an errno other than ENOENT and ENODEV
inline bool VirtgpuTransferNeeded() {
  static const bool needed = [] {
    int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (fd < 0) return errno != ENOENT && errno != ENODEV;
    bool virtgpu = IsVirtgpuNode(fd);
    close(fd);
    return virtgpu;
  }();
  return needed;
}

// create a virgl context on drmFd
inline bool InitVirglContext(int drmFd) {
  int hasContextInit = 0;
  struct drm_virtgpu_getparam gp {};
  gp.param = VIRTGPU_PARAM_CONTEXT_INIT;
  gp.value = reinterpret_cast<uintptr_t>(&hasContextInit);
  if (ioctl(drmFd, DRM_IOCTL_VIRTGPU_GETPARAM, &gp) != 0) {
    if (errno != ENOSYS && errno != EINVAL) return false;
    NoteNoContextInit("DRM_IOCTL_VIRTGPU_GETPARAM");
    return true;
  }
  if (hasContextInit == 0) {
    NoteNoContextInit("VIRTGPU_PARAM_CONTEXT_INIT=0");
    return true;
  }
  int capsetMask = 0;
  gp.param = VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs;
  gp.value = reinterpret_cast<uintptr_t>(&capsetMask);
  if (ioctl(drmFd, DRM_IOCTL_VIRTGPU_GETPARAM, &gp) != 0) return false;
  constexpr int kCapsetVirgl = 1;
  constexpr int kCapsetVirgl2 = 2;
  struct drm_virtgpu_context_set_param capset {};
  capset.param = VIRTGPU_CONTEXT_PARAM_CAPSET_ID;
  if (capsetMask & (1 << kCapsetVirgl2)) capset.value = kCapsetVirgl2;
  else if (capsetMask & (1 << kCapsetVirgl)) capset.value = kCapsetVirgl;
  else return false;
  struct drm_virtgpu_context_init init {};
  init.num_params = 1;
  init.ctx_set_params = reinterpret_cast<uintptr_t>(&capset);
  if (ioctl(drmFd, DRM_IOCTL_VIRTGPU_CONTEXT_INIT, &init) == 0) return true;
  if (errno != ENOSYS && errno != EINVAL) return false;
  NoteNoContextInit("DRM_IOCTL_VIRTGPU_CONTEXT_INIT");
  return true;
}

// return a static /dev/dri/renderD128 fd with a virgl context
inline int OpenRenderNode() {
  static const int fd = [] {
    int drmFd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (drmFd < 0) return -1;
    if (!IsVirtgpuNode(drmFd) || !InitVirglContext(drmFd)) {
      close(drmFd);
      return -1;
    }
    return drmFd;
  }();
  return fd;
}

// wait on handle with DRM_IOCTL_VIRTGPU_WAIT
inline bool VirtgpuWaitHandle(int drmFd, uint32_t handle) {
  struct drm_virtgpu_3d_wait wait_req {};
  wait_req.handle = handle;
  wait_req.flags = 0;
  return ioctl(drmFd, DRM_IOCTL_VIRTGPU_WAIT, &wait_req) == 0;
}

// copy the host resource of dmabufFd into the guest buffer with DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST
inline bool VirtgpuTransferFromHost(int dmabufFd, int width, int height, int  ,
                                     bool wait = true) {
  int drmFd = OpenRenderNode();
  if (drmFd < 0) return false;

  struct drm_prime_handle prime {};
  prime.fd = dmabufFd;
  if (ioctl(drmFd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) != 0) {
    return false;
  }

  struct drm_virtgpu_3d_transfer_from_host xfer {};
  xfer.bo_handle = prime.handle;
  xfer.box.x = 0;
  xfer.box.y = 0;
  xfer.box.z = 0;
  xfer.box.w = static_cast<uint32_t>(width);
  xfer.box.h = static_cast<uint32_t>(height);
  xfer.box.d = 1;
  xfer.level = 0;
  xfer.offset = 0;
  xfer.stride = 0;
  xfer.layer_stride = 0;
  int rc = ioctl(drmFd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &xfer);
  bool waited = !wait || (rc == 0 && VirtgpuWaitHandle(drmFd, prime.handle));

  struct drm_gem_close close_req {};
  close_req.handle = prime.handle;
  ioctl(drmFd, DRM_IOCTL_GEM_CLOSE, &close_req);

  return rc == 0 && waited;
}

// copy the guest buffer of handle to the host resource with DRM_IOCTL_VIRTGPU_TRANSFER_TO_HOST
inline bool VirtgpuTransferToHostHandle(int drmFd, uint32_t handle, int width, int height) {
  struct drm_virtgpu_3d_transfer_to_host xfer {};
  xfer.bo_handle = handle;
  xfer.box.w = static_cast<uint32_t>(width);
  xfer.box.h = static_cast<uint32_t>(height);
  xfer.box.d = 1;
  int rc = ioctl(drmFd, DRM_IOCTL_VIRTGPU_TRANSFER_TO_HOST, &xfer);
  return rc == 0 && VirtgpuWaitHandle(drmFd, handle);
}

// copy the guest buffer of dmabufFd to the host resource with DRM_IOCTL_VIRTGPU_TRANSFER_TO_HOST
inline bool VirtgpuTransferToHost(int dmabufFd, int width, int height, int  ,
                                   bool wait = true) {
  int drmFd = OpenRenderNode();
  if (drmFd < 0) return false;

  struct drm_prime_handle prime {};
  prime.fd = dmabufFd;
  if (ioctl(drmFd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) != 0) {
    return false;
  }

  struct drm_virtgpu_3d_transfer_to_host xfer {};
  xfer.bo_handle = prime.handle;
  xfer.box.x = 0;
  xfer.box.y = 0;
  xfer.box.z = 0;
  xfer.box.w = static_cast<uint32_t>(width);
  xfer.box.h = static_cast<uint32_t>(height);
  xfer.box.d = 1;
  xfer.level = 0;
  xfer.offset = 0;
  xfer.stride = 0;
  xfer.layer_stride = 0;
  int rc = ioctl(drmFd, DRM_IOCTL_VIRTGPU_TRANSFER_TO_HOST, &xfer);
  bool waited = !wait || (rc == 0 && VirtgpuWaitHandle(drmFd, prime.handle));

  struct drm_gem_close close_req {};
  close_req.handle = prime.handle;
  ioctl(drmFd, DRM_IOCTL_GEM_CLOSE, &close_req);

  return rc == 0 && waited;
}

}

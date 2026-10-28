#ifndef RHIZO_CAMERA_GRALLOC_H
#define RHIZO_CAMERA_GRALLOC_H

// lock output buffers with rhizo's mapper

#include <stddef.h>
#include <stdint.h>

#include <cutils/native_handle.h>

#include "plane_layout.h"

struct AIMapper;

namespace rhizo::camera {

class Gralloc {
 public:
  static Gralloc* Get();

  buffer_handle_t importBuffer(const native_handle_t* raw);
  void freeBuffer(buffer_handle_t buffer);
  bool lock(buffer_handle_t buffer, LockedBuffer* out);
  bool unlock(buffer_handle_t buffer, int* releaseFence);

 private:
  explicit Gralloc(AIMapper* mapper) : mapper_(mapper) {}
  bool metadataU64(buffer_handle_t buffer, int64_t type, uint64_t* out);
  AIMapper* mapper_;
};

}

#endif

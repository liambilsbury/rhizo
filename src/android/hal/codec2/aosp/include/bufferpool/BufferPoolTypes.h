#ifndef RHIZO_C2_AOSP_HIDL_BUFFERPOOL_TYPES_H
#define RHIZO_C2_AOSP_HIDL_BUFFERPOOL_TYPES_H

// the HIDL bufferpool 2.0 types

#include <stddef.h>
#include <stdint.h>

#include <memory>
#include <vector>

#include <cutils/native_handle.h>

#include <android/hardware/media/bufferpool/2.0/types.h>

namespace android::hardware::media::bufferpool {

struct BufferPoolData {
  int64_t mConnectionId;
  uint32_t mId;

  BufferPoolData() : mConnectionId(0), mId(0) {}
  BufferPoolData(int64_t connectionId, uint32_t id) : mConnectionId(connectionId), mId(id) {}
  ~BufferPoolData() {}
};

namespace V2_0::implementation {

typedef uint32_t BufferId;
typedef uint64_t TransactionId;
typedef int64_t ConnectionId;

enum : ConnectionId {
  INVALID_CONNECTIONID = 0,
};

struct BufferPoolAllocation {
  const native_handle_t* mHandle;

  const native_handle_t* handle() { return mHandle; }

  BufferPoolAllocation(const native_handle_t* handle) : mHandle(handle) {}
  ~BufferPoolAllocation() {}
};

class BufferPoolAllocator {
 public:
  virtual ResultStatus allocate(const std::vector<uint8_t>& params, std::shared_ptr<BufferPoolAllocation>* alloc,
                                size_t* allocSize) = 0;
  virtual bool compatible(const std::vector<uint8_t>& newParams, const std::vector<uint8_t>& oldParams) = 0;

 protected:
  BufferPoolAllocator() = default;
  virtual ~BufferPoolAllocator() = default;
};

}
}

#endif

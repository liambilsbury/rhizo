// the HIDL BufferQueue block pool, without a BufferQueue: every fetch fails

#include <C2AllocatorGralloc.h>
#include <C2BlockInternal.h>
#include <C2BqBufferPriv.h>

// return no BufferQueue data
bool _C2BlockFactory::GetBufferQueueData(const std::shared_ptr<const _C2BlockPoolData>&, uint32_t*, uint64_t*,
                                         int32_t*) {
  return false;
}

// unreachable: no block carries BufferQueue data
bool _C2BlockFactory::BeginTransferBlockToClient(const std::shared_ptr<_C2BlockPoolData>&) { return false; }

bool _C2BlockFactory::EndTransferBlockToClient(const std::shared_ptr<_C2BlockPoolData>&, bool) { return false; }

bool _C2BlockFactory::DisplayBlockToBufferQueue(const std::shared_ptr<_C2BlockPoolData>&) { return false; }

// wrap a client's gralloc handle in a graphic block
// (from AOSP's C2BqBuffer.cpp, Apache-2.0, The Android Open Source Project)
std::shared_ptr<C2GraphicBlock> _C2BlockFactory::CreateGraphicBlock(const C2Handle* handle) {
  static std::unique_ptr<android::C2AllocatorGralloc> sAllocator = std::make_unique<android::C2AllocatorGralloc>(0);
  std::shared_ptr<C2GraphicAllocation> alloc;
  if (!android::C2AllocatorGralloc::CheckHandle(handle)) return nullptr;
  if (sAllocator->priorGraphicAllocation(handle, &alloc) != C2_OK) return nullptr;
  return _C2BlockFactory::CreateGraphicBlock(alloc);
}

C2BufferQueueBlockPool::C2BufferQueueBlockPool(const std::shared_ptr<C2Allocator>& allocator,
                                               const local_id_t localId)
    : mAllocator(allocator), mLocalId(localId) {}

C2BufferQueueBlockPool::~C2BufferQueueBlockPool() {}

c2_status_t C2BufferQueueBlockPool::fetchGraphicBlock(uint32_t, uint32_t, uint32_t, C2MemoryUsage,
                                                      std::shared_ptr<C2GraphicBlock>* block) {
  block->reset();
  return C2_OMITTED;
}

c2_status_t C2BufferQueueBlockPool::fetchGraphicBlock(uint32_t, uint32_t, uint32_t, C2MemoryUsage,
                                                      std::shared_ptr<C2GraphicBlock>* block, C2Fence* fence) {
  block->reset();
  *fence = C2Fence();
  return C2_OMITTED;
}

void C2BufferQueueBlockPool::setRenderCallback(const OnRenderCallback&) {}

void C2BufferQueueBlockPool::configureProducer(const android::sp<HGraphicBufferProducer>&) {}

void C2BufferQueueBlockPool::configureProducer(const android::sp<HGraphicBufferProducer>&, native_handle_t*,
                                               uint64_t, uint32_t, uint64_t) {}

void C2BufferQueueBlockPool::getConsumerUsage(uint64_t* consumerUsage) { *consumerUsage = 0; }

void C2BufferQueueBlockPool::invalidate() {}

void C2BufferQueueBlockPool::setDeferDeallocationAfterStop() {}

void C2BufferQueueBlockPool::clearDeferredBlocks() {}

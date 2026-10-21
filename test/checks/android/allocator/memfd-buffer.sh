#!/bin/bash
# test the allocator's memfd buffers
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
g++ -std=c++17 -Wall -Werror -I src/android/hal/common/include -o "$tmp/memfd_buffer_test" \
  src/android/hal/graphics-allocator/tests/memfd_buffer_test.cpp || { echo "FAIL: memfd_buffer_test.cpp did not build"; exit 1; }
"$tmp/memfd_buffer_test" || exit 1
grep -q 'MemfdBufferBytes(boStride, height)' src/android/hal/graphics-allocator/src/allocator.cpp \
  || { echo "FAIL: allocator.cpp does not size its image memfds with MemfdBufferBytes"; exit 1; }
grep -q 'MemfdYuv420Bytes(yv12LumaStride, yv12ChromaStride, descriptor.height)' src/android/hal/graphics-allocator/src/allocator.cpp \
  || { echo "FAIL: allocator.cpp does not size its YUV 4:2:0 memfds with MemfdYuv420Bytes"; exit 1; }
grep -q 'if (boStride < 0) return allocationError' src/android/hal/graphics-allocator/src/allocator.cpp \
  || { echo "FAIL: allocator.cpp does not refuse a memfd stride LinearStrideBytes rejects"; exit 1; }
grep -q 'if (!rhizo::MemfdBufferFits(allocSize))' src/android/hal/graphics-allocator/src/allocator.cpp \
  || { echo "FAIL: allocator.cpp does not refuse a memfd buffer past kMaxMemfdBufferBytes"; exit 1; }
grep -q 'if (!rhizo::ShmemImportAllowed(handle->data\[0\], decoded.allocSize))' src/android/hal/gralloc-mapper/src/mapper.cpp \
  || { echo "FAIL: mapper.cpp's importBuffer does not refuse a shmem fd ShmemImportAllowed rejects"; exit 1; }

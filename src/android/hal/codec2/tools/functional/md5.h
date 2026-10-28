#ifndef RHIZO_C2VA_FUNCTIONAL_MD5_H
#define RHIZO_C2VA_FUNCTIONAL_MD5_H

// compute RFC 1321 MD5 digests of decoded frames

#include <stddef.h>
#include <stdint.h>

#include <string>

namespace rhizo::c2va {

class Md5 {
 public:
  Md5();
  void Update(const void* data, size_t size);
  // return the digest as 32 lowercase hex digits
  std::string HexDigest();

 private:
  void Block(const uint8_t* p);
  uint32_t a_, b_, c_, d_;
  uint64_t bytes_ = 0;
  uint8_t buf_[64];
  size_t used_ = 0;
};

}

#endif

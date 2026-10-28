#ifndef RHIZO_C2VA_AV1_BITS_H
#define RHIZO_C2VA_AV1_BITS_H

// the AV1 descriptors

#include <stddef.h>
#include <stdint.h>

#include "common/bit_reader.h"

namespace rhizo::c2va::av1 {

// record each parsed element and structure boundary
class Trace {
 public:
  virtual ~Trace() = default;
  virtual void Element(size_t bit_pos, int bits, const char* name, int i, int j, int64_t value) = 0;
  // record a structure boundary
  virtual void Section(const char* name) = 0;
};

// return FloorLog2(x) for x >= 1
inline int FloorLog2(uint32_t x) {
  int s = 0;
  while (x > 1) {
    x >>= 1;
    s++;
  }
  return s;
}

class Bits {
 public:
  // read data whose trace positions start at base_bits
  Bits(const uint8_t* data, size_t size, size_t base_bits = 0, Trace* trace = nullptr)
      : r_(data, size), base_(base_bits), trace_(trace) {}

  // read f(n) for n <= 32
  uint32_t f(int n, const char* name, int i = -1, int j = -1) {
    size_t pos = r_.BitPos();
    uint32_t v = r_.U(n);
    if (trace_ && n > 0) trace_->Element(base_ + pos, n, name, i, j, v);
    return v;
  }
  bool flag(const char* name, int i = -1, int j = -1) { return f(1, name, i, j) != 0; }

  // read su(n) for 1 <= n <= 31
  int32_t su(int n, const char* name, int i = -1, int j = -1) {
    size_t pos = r_.BitPos();
    int64_t v = r_.U(n);
    int64_t sign = int64_t{1} << (n - 1);
    if (v & sign) v -= 2 * sign;
    if (trace_) trace_->Element(base_ + pos, n, name, i, j, v);
    return static_cast<int32_t>(v);
  }

  // read ns(n) for n >= 1
  uint32_t ns(uint32_t n, const char* name, int i = -1, int j = -1) {
    size_t pos = r_.BitPos();
    int w = FloorLog2(n) + 1;
    uint32_t m = (1u << w) - n;
    uint32_t v = r_.U(w - 1);
    uint32_t out = v;
    int bits = w - 1;
    if (v >= m) {
      out = (v << 1) - m + r_.U(1);
      bits = w;
    }
    if (trace_) trace_->Element(base_ + pos, bits, name, i, j, out);
    return out;
  }

  // read le(n) for 1 <= n <= 4
  uint32_t le(int n, const char* name, int i = -1, int j = -1) {
    size_t pos = r_.BitPos();
    uint32_t t = 0;
    for (int k = 0; k < n; k++) t |= r_.U(8) << (k * 8);
    if (trace_) trace_->Element(base_ + pos, 8 * n, name, i, j, t);
    return t;
  }

  // read uvlc() up to the end of the data
  uint32_t uvlc(const char* name) {
    size_t pos = r_.BitPos();
    int leading_zeros = 0;
    while (!r_.Flag()) {
      if (r_.overrun()) break;
      leading_zeros++;
    }
    uint32_t v;
    if (leading_zeros >= 32) {
      v = UINT32_MAX;
    } else {
      v = r_.U(leading_zeros) + ((1u << leading_zeros) - 1);
    }
    if (trace_) trace_->Element(base_ + pos, static_cast<int>(r_.BitPos() - pos), name, -1, -1, v);
    return v;
  }

  // skip to the next byte boundary
  void ByteAlign() {
    while (!r_.ByteAligned() && !r_.overrun()) f(1, "zero_bit");
  }

  size_t BitPos() const { return r_.BitPos(); }
  size_t BitsLeft() const { return r_.BitsLeft(); }
  bool overrun() const { return r_.overrun(); }
  Trace* trace() const { return trace_; }

 private:
  BitReader r_;
  size_t base_;
  Trace* trace_;
};

}

#endif

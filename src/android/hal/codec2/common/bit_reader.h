#ifndef RHIZO_C2VA_BIT_READER_H
#define RHIZO_C2VA_BIT_READER_H

// MSB-first bit reading and the H.264/HEVC byte-stream helpers

#include <stddef.h>
#include <stdint.h>

#include <vector>

namespace rhizo::c2va {

class BitReader {
 public:
  BitReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

  // read u(n)
  uint32_t U(int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) v = (v << 1) | Bit();
    return v;
  }
  bool Flag() { return Bit() != 0; }

  // read an Exp-Golomb ue(v)
  uint32_t Ue() {
    int zeros = 0;
    while (Bit() == 0) {
      if (overrun_ || ++zeros > 31) {
        overrun_ = true;
        return 0;
      }
    }
    if (zeros == 0) return 0;
    return ((1u << zeros) - 1) + U(zeros);
  }
  // read a signed Exp-Golomb se(v)
  int32_t Se() {
    uint32_t k = Ue();
    return (k & 1) ? static_cast<int32_t>((k + 1) / 2) : -static_cast<int32_t>(k / 2);
  }

  void Skip(size_t bits) {
    pos_ += bits;
    if (pos_ > size_ * 8) {
      pos_ = size_ * 8;
      overrun_ = true;
    }
  }
  void ByteAlign() { pos_ = (pos_ + 7) & ~static_cast<size_t>(7); }
  bool ByteAligned() const { return (pos_ & 7) == 0; }

  size_t BitPos() const { return pos_; }
  size_t BitsLeft() const { return size_ * 8 - pos_; }
  bool overrun() const { return overrun_; }

  // return true when data remains before the rbsp stop bit
  bool MoreRbspData() const {
    if (pos_ >= size_ * 8) return false;
    size_t last = size_;
    while (last > 0 && data_[last - 1] == 0) last--;
    if (last == 0) return false;
    uint8_t b = data_[last - 1];
    int stop = 0;
    while (((b >> stop) & 1) == 0) stop++;
    size_t stop_pos = (last - 1) * 8 + (7 - stop);
    return pos_ < stop_pos;
  }

 private:
  uint32_t Bit() {
    if (pos_ >= size_ * 8) {
      overrun_ = true;
      return 0;
    }
    uint32_t b = (data_[pos_ >> 3] >> (7 - (pos_ & 7))) & 1;
    pos_++;
    return b;
  }

  const uint8_t* data_;
  size_t size_;
  size_t pos_ = 0;
  bool overrun_ = false;
};

// a NAL unit inside an Annex B buffer without its start code
struct NalSpan {
  const uint8_t* data;
  size_t size;
};

// split an Annex B byte stream into NAL units
inline std::vector<NalSpan> SplitAnnexB(const uint8_t* data, size_t size) {
  std::vector<NalSpan> out;
  size_t i = 0;
  auto start_code_at = [&](size_t p) { return p + 2 < size && data[p] == 0 && data[p + 1] == 0 && data[p + 2] == 1; };
  while (i + 2 < size && !start_code_at(i)) i++;
  while (i + 2 < size) {
    size_t begin = i + 3;
    size_t j = begin;
    while (j + 2 < size && !start_code_at(j)) j++;
    size_t end = (j + 2 < size) ? j : size;
    while (end > begin && data[end - 1] == 0) end--;
    if (end > begin) out.push_back({data + begin, end - begin});
    i = j;
  }
  return out;
}

// return a NAL unit's RBSP without its emulation prevention bytes
inline std::vector<uint8_t> Unescape(const uint8_t* data, size_t size) {
  std::vector<uint8_t> out;
  out.reserve(size);
  int zeros = 0;
  for (size_t i = 0; i < size; i++) {
    if (zeros >= 2 && data[i] == 3) {
      zeros = 0;
      continue;
    }
    zeros = (data[i] == 0) ? zeros + 1 : 0;
    out.push_back(data[i]);
  }
  return out;
}

}

#endif

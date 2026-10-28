#ifndef RHIZO_C2VA_ENC_BIT_WRITER_H
#define RHIZO_C2VA_ENC_BIT_WRITER_H

// the H.264/HEVC bit writer and Annex B NAL assembly

#include <stddef.h>
#include <stdint.h>

#include <vector>

#include "../../common/bit_reader.h"

namespace rhizo::c2va {

class BitWriter {
 public:
  // write u(n)
  void U(int n, uint32_t v) {
    for (int i = n - 1; i >= 0; i--) Bit((v >> i) & 1);
  }
  void Flag(bool b) { Bit(b ? 1 : 0); }

  // write ue(v)
  void Ue(uint32_t v) {
    uint64_t x = static_cast<uint64_t>(v) + 1;
    int len = 0;
    while ((x >> (len + 1)) != 0) len++;
    for (int i = 0; i < len; i++) Bit(0);
    for (int i = len; i >= 0; i--) Bit(static_cast<uint32_t>((x >> i) & 1));
  }
  // write se(v)
  void Se(int32_t v) {
    int64_t k = v;
    Ue(static_cast<uint32_t>(k > 0 ? 2 * k - 1 : -2 * k));
  }

  // write rbsp_trailing_bits()
  void TrailingBits() {
    Bit(1);
    while (!ByteAligned()) Bit(0);
  }
  // write the H.265 byte_alignment()
  void ByteAlignment() { TrailingBits(); }
  // pad to a byte with cabac_alignment_one_bit
  void AlignWithOnes() {
    while (!ByteAligned()) Bit(1);
  }
  void AlignWithZeros() {
    while (!ByteAligned()) Bit(0);
  }

  bool ByteAligned() const { return nbits_ == 0; }
  size_t BitPos() const { return bytes_.size() * 8 + nbits_; }

  // append bytes to a byte-aligned writer
  void AppendBytes(const uint8_t* data, size_t size) { bytes_.insert(bytes_.end(), data, data + size); }

  // copy nbits bits from a reader at any alignment
  void CopyBits(BitReader* r, size_t nbits) {
    while (nbits >= 32) {
      U(32, r->U(32));
      nbits -= 32;
    }
    if (nbits) U(static_cast<int>(nbits), r->U(static_cast<int>(nbits)));
  }

  // return the bytes with a partial last byte zero-padded
  std::vector<uint8_t> Bytes() const {
    std::vector<uint8_t> out = bytes_;
    if (nbits_) out.push_back(static_cast<uint8_t>(cur_ << (8 - nbits_)));
    return out;
  }

 private:
  void Bit(uint32_t b) {
    cur_ = static_cast<uint8_t>((cur_ << 1) | (b & 1));
    if (++nbits_ == 8) {
      bytes_.push_back(cur_);
      cur_ = 0;
      nbits_ = 0;
    }
  }

  std::vector<uint8_t> bytes_;
  uint8_t cur_ = 0;
  int nbits_ = 0;
};

// append the rbsp with emulation prevention bytes
inline void AppendEscaped(const uint8_t* rbsp, size_t size, std::vector<uint8_t>* out, bool final_zero_rule) {
  int zeros = 0;
  for (size_t i = 0; i < size; i++) {
    if (zeros >= 2 && rbsp[i] <= 0x03) {
      out->push_back(0x03);
      zeros = 0;
    }
    out->push_back(rbsp[i]);
    zeros = (rbsp[i] == 0) ? zeros + 1 : 0;
  }
  if (final_zero_rule && size > 0 && rbsp[size - 1] == 0) out->push_back(0x03);
}

// append a start code, header and escaped RBSP
inline void AppendNal(const uint8_t* header, size_t header_size, const std::vector<uint8_t>& rbsp,
                      std::vector<uint8_t>* out) {
  static const uint8_t kStartCode[4] = {0, 0, 0, 1};
  out->insert(out->end(), kStartCode, kStartCode + 4);
  out->insert(out->end(), header, header + header_size);
  AppendEscaped(rbsp.data(), rbsp.size(), out, true);
}

// append a start code and an escaped NAL unit
inline void AppendRawNal(const uint8_t* nal, size_t size, std::vector<uint8_t>* out) {
  static const uint8_t kStartCode[4] = {0, 0, 0, 1};
  out->insert(out->end(), kStartCode, kStartCode + 4);
  out->insert(out->end(), nal, nal + size);
}

// find the bit index of rbsp_stop_one_bit
inline bool RbspStopBit(const std::vector<uint8_t>& rbsp, size_t* pos) {
  size_t last = rbsp.size();
  while (last > 0 && rbsp[last - 1] == 0) last--;
  if (last == 0) return false;
  uint8_t b = rbsp[last - 1];
  int stop = 0;
  while (((b >> stop) & 1) == 0) stop++;
  *pos = (last - 1) * 8 + static_cast<size_t>(7 - stop);
  return true;
}

}

#endif

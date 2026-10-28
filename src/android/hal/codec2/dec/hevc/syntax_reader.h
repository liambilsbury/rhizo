#ifndef RHIZO_C2VA_HEVC_SYNTAX_READER_H
#define RHIZO_C2VA_HEVC_SYNTAX_READER_H

// a BitReader with an optional syntax trace

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "../../common/bit_reader.h"

namespace rhizo::c2va::hevc {

// receiver of the traced syntax elements
class TraceSink {
 public:
  virtual ~TraceSink() = default;
  virtual void NalBegin(int nal_unit_type) = 0;
  virtual void Element(size_t bit_pos, const char* name, int64_t value) = 0;
};

class SyntaxReader {
 public:
  SyntaxReader(const uint8_t* data, size_t size, TraceSink* trace) : br_(data, size), trace_(trace) {}

  uint32_t U(int n, const char* name) {
    size_t pos = br_.BitPos();
    uint32_t v = br_.U(n);
    Emit(pos, name, -1, -1, v);
    return v;
  }
  bool Flag(const char* name) { return U(1, name) != 0; }
  uint32_t Ue(const char* name) {
    size_t pos = br_.BitPos();
    uint32_t v = br_.Ue();
    Emit(pos, name, -1, -1, v);
    return v;
  }
  int32_t Se(const char* name) {
    size_t pos = br_.BitPos();
    int32_t v = br_.Se();
    Emit(pos, name, -1, -1, v);
    return v;
  }

  // read an element traced as name[i] or name[i][j]
  uint32_t U(int n, const char* name, int i, int j = -1) {
    size_t pos = br_.BitPos();
    uint32_t v = br_.U(n);
    Emit(pos, name, i, j, v);
    return v;
  }
  bool Flag(const char* name, int i, int j = -1) { return U(1, name, i, j) != 0; }
  uint32_t Ue(const char* name, int i, int j = -1) {
    size_t pos = br_.BitPos();
    uint32_t v = br_.Ue();
    Emit(pos, name, i, j, v);
    return v;
  }
  int32_t Se(const char* name, int i, int j = -1) {
    size_t pos = br_.BitPos();
    int32_t v = br_.Se();
    Emit(pos, name, i, j, v);
    return v;
  }

  void Skip(size_t bits) { br_.Skip(bits); }
  void ByteAlign() { br_.ByteAlign(); }
  bool ByteAligned() const { return br_.ByteAligned(); }
  size_t BitPos() const { return br_.BitPos(); }
  size_t BitsLeft() const { return br_.BitsLeft(); }
  bool overrun() const { return br_.overrun(); }
  bool MoreRbspData() const { return br_.MoreRbspData(); }

 private:
  void Emit(size_t pos, const char* name, int i, int j, int64_t v) {
    if (!trace_) return;
    if (i < 0) {
      trace_->Element(pos, name, v);
      return;
    }
    char buf[96];
    if (j < 0)
      snprintf(buf, sizeof(buf), "%s[%d]", name, i);
    else
      snprintf(buf, sizeof(buf), "%s[%d][%d]", name, i, j);
    trace_->Element(pos, buf, v);
  }

  BitReader br_;
  TraceSink* trace_;
};

}

#endif

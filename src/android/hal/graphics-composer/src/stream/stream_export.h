#pragma once

#include <cstdint>

#include "rhizo/stream_protocol.h"

namespace rhizo {

// frame sent to rhizo-streamd
struct StreamFrame {
  int dmabufFd = -1;
  int32_t width = 0;
  int32_t height = 0;
  int32_t strideBytes = 0;
  int32_t offsetBytes = 0;
  uint32_t drmFormat = 0;
  uint64_t modifier = 0;
  int64_t presentedNs = 0;
};

// frame export to rhizo-streamd
class StreamExportBackend {
 public:
  StreamExportBackend();
  ~StreamExportBackend();

  StreamExportBackend(const StreamExportBackend&) = delete;
  StreamExportBackend& operator=(const StreamExportBackend&) = delete;

  bool EnsureConnected();

  bool Connected() const;

  bool Present(const StreamFrame& frame);

  void Disconnect();

 private:
  struct Impl;
  Impl* impl_;
};

}

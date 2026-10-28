#ifndef RHIZO_STREAM_PROTOCOL_H
#define RHIZO_STREAM_PROTOCOL_H

#include <stdint.h>

#define RHIZO_STREAM_PROTOCOL_VERSION 1u

#define RHIZO_STREAM_SOCKET_NAME "streamd"

#define RHIZO_STREAM_FRAME_MAGIC 0x52535431u
#define RHIZO_STREAM_ACK_MAGIC   0x52534b31u

// header for a presented frame
struct rhizo_stream_frame_header {
  uint32_t magic;
  uint32_t version;
  uint64_t seq;
  int64_t presented_ns;
  int32_t width;
  int32_t height;
  uint32_t drm_fourcc;
  uint64_t modifier;
  int32_t stride_bytes;
  int32_t offset_bytes;
};

// release reply for a frame
struct rhizo_stream_release_ack {
  uint32_t magic;
  uint64_t seq;
};

#endif

#ifndef RHIZO_CAMERA_PROTOCOL_H
#define RHIZO_CAMERA_PROTOCOL_H

// define the socket protocol between rhizo-camerad and the camera HAL

#include <stdint.h>

#define RHIZO_CAMERA_PROTOCOL_VERSION 1u

#define RHIZO_CAMERA_SOCKET_NAME "camerad"

#define RHIZO_CAMERA_MAGIC 0x52434d31u

#define RHIZO_CAMERA_KEY_LEN 64
#define RHIZO_CAMERA_NAME_LEN 128
#define RHIZO_CAMERA_MAX_MODES 32
#define RHIZO_CAMERA_MAX_CAMERAS 8

#define RHIZO_CAMERA_MAX_PAYLOAD (64u + 4096u * 4096u * 3u / 2u)

enum rhizo_camera_msg_type {
  RHIZO_CAMERA_HELLO = 1,
  RHIZO_CAMERA_OPEN = 2,
  RHIZO_CAMERA_CLOSE = 3,
  RHIZO_CAMERA_LIST = 16,
  RHIZO_CAMERA_STARTED = 17,
  RHIZO_CAMERA_FRAME = 18,
  RHIZO_CAMERA_STOPPED = 19,
};

enum rhizo_camera_facing {
  RHIZO_CAMERA_FACING_FRONT = 0,
  RHIZO_CAMERA_FACING_BACK = 1,
  RHIZO_CAMERA_FACING_EXTERNAL = 2,
};

struct rhizo_camera_msg_header {
  uint32_t magic;
  uint32_t type;
  uint32_t length;
  uint32_t reserved;
};

struct rhizo_camera_hello {
  uint32_t version;
  uint32_t reserved;
};

// a camera size and its highest frame rate
struct rhizo_camera_mode {
  uint32_t width;
  uint32_t height;
  uint32_t fps_num;
  uint32_t fps_den;
};

// a host camera, keyed by its PipeWire node.name
struct rhizo_camera_info {
  char key[RHIZO_CAMERA_KEY_LEN];
  char name[RHIZO_CAMERA_NAME_LEN];
  uint32_t facing;
  uint32_t mode_count;
  struct rhizo_camera_mode modes[RHIZO_CAMERA_MAX_MODES];
};

// a camera list header, followed by count rhizo_camera_info entries
struct rhizo_camera_list {
  uint32_t version;
  uint32_t count;
};

// a stream request for a camera mode
struct rhizo_camera_open {
  char key[RHIZO_CAMERA_KEY_LEN];
  uint32_t stream_id;
  uint32_t width;
  uint32_t height;
  uint32_t fps_num;
  uint32_t fps_den;
  uint32_t reserved;
};

struct rhizo_camera_close {
  uint32_t stream_id;
  uint32_t reserved;
};

// a started stream and the rate of its frames
struct rhizo_camera_started {
  uint32_t stream_id;
  uint32_t width;
  uint32_t height;
  uint32_t fps_num;
  uint32_t fps_den;
  uint32_t reserved;
};

// a frame header, followed by unpadded I420 planes
struct rhizo_camera_frame {
  uint32_t stream_id;
  uint32_t width;
  uint32_t height;
  uint32_t reserved;
  uint64_t seq;
  int64_t monotonic_ns;
};

struct rhizo_camera_stopped {
  uint32_t stream_id;
  int32_t error;
};

#endif

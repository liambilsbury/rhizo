#ifndef RHIZO_CAMERA_STATIC_METADATA_H
#define RHIZO_CAMERA_STATIC_METADATA_H

// build a host camera's characteristics, request templates and results

#include <stddef.h>
#include <stdint.h>

#include <array>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <system/camera_metadata.h>

#include "camerad_client.h"

namespace rhizo::camera {

constexpr int32_t kMaxProcessedStreams = 3;
constexpr int32_t kMaxStallStreams = 1;
constexpr int32_t kPipelineMaxDepth = 4;
constexpr int32_t kDefaultJpegQuality = 90;

// an output size cropped and scaled from a larger host mode
struct OutputSize {
  int32_t width = 0;
  int32_t height = 0;
  int64_t minFrameDurationNs = 0;
};

// the advertised sizes and ranges of a camera
struct CameraShape {
  std::vector<OutputSize> sizes;
  int32_t arrayWidth = 0;
  int32_t arrayHeight = 0;
  std::vector<std::array<int32_t, 2>> fpsRanges;
  std::array<int32_t, 2> previewFps{};
  std::array<int32_t, 2> recordFps{};
  std::vector<std::array<int32_t, 2>> thumbnailSizes;
  int32_t jpegMaxSize = 0;
  int64_t maxFrameDurationNs = 0;
};

// the JPEG settings of a request
struct JpegSettings {
  int32_t quality = kDefaultJpegQuality;
  int32_t thumbnailQuality = kDefaultJpegQuality;
  int32_t orientation = 0;
  int32_t thumbnailWidth = 0;
  int32_t thumbnailHeight = 0;
};

// builder of a sorted camera_metadata_t blob
class MetadataBuilder {
 public:
  bool setU8(uint32_t tag, const std::vector<uint8_t>& v) { return set(tag, TYPE_BYTE, v.data(), v.size()); }
  bool setI32(uint32_t tag, const std::vector<int32_t>& v) { return set(tag, TYPE_INT32, v.data(), v.size()); }
  bool setI64(uint32_t tag, const std::vector<int64_t>& v) { return set(tag, TYPE_INT64, v.data(), v.size()); }
  bool setFloat(uint32_t tag, const std::vector<float>& v) { return set(tag, TYPE_FLOAT, v.data(), v.size()); }
  bool setRational(uint32_t tag, const std::vector<camera_metadata_rational_t>& v) {
    return set(tag, TYPE_RATIONAL, v.data(), v.size());
  }
  bool has(uint32_t tag) const { return entries_.count(tag) != 0; }
  std::vector<int32_t> tags() const;
  std::vector<uint8_t> finish() const;

 private:
  struct Entry {
    uint8_t type;
    size_t count;
    std::vector<uint8_t> bytes;
  };
  bool set(uint32_t tag, uint8_t type, const void* data, size_t count);
  std::map<uint32_t, Entry> entries_;
};

// deleter of owned request settings
struct MetadataDeleter {
  void operator()(camera_metadata_t* m) const;
};
using MetadataPtr = std::unique_ptr<camera_metadata_t, MetadataDeleter>;

MetadataPtr ParseMetadata(const std::vector<uint8_t>& blob);
bool ValidMetadataBlob(const std::vector<uint8_t>& blob);

CameraShape ShapeFor(const std::vector<HostMode>& modes);
bool ShapeHasSize(const CameraShape& shape, int32_t width, int32_t height);
int ChooseModeBySize(const std::vector<HostMode>& modes, int32_t width, int32_t height);
int ChooseMode(const std::vector<HostMode>& modes, int32_t width, int32_t height, int32_t maxFps = 0);
int32_t RequestedMaxFps(const CameraShape& shape, const camera_metadata_t* settings);
std::vector<uint8_t> BuildCharacteristics(const CameraShape& shape);
std::vector<uint8_t> BuildDefaultRequest(const CameraShape& shape, int32_t requestTemplate);
std::vector<uint8_t> BuildSessionCharacteristics();
std::vector<uint8_t> BuildResult(const CameraShape& shape, const camera_metadata_t* settings,
                                 int64_t timestampNs, int32_t pipelineDepth);
JpegSettings JpegSettingsFrom(const CameraShape& shape, const camera_metadata_t* settings);

}

#endif

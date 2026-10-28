#include "static_metadata.h"

#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <cmath>
#include <numeric>
#include <set>

#include "log.h"

namespace rhizo::camera {

namespace {

constexpr int64_t kNsPerSecond = 1000000000LL;
constexpr int32_t kVariableFpsFloor = 15;
constexpr int32_t kDefaultMaxFps = 30;
constexpr std::array<int32_t, 4> kPacedRates = {15, 20, 24, 30};
constexpr int32_t kArrayThumbnailArea = 320 * 240;
constexpr int32_t kJpegMinMaxSize = 512 * 1024;
constexpr int32_t kJpegHeadroom = 128 * 1024;

constexpr std::array<std::array<int32_t, 2>, 11> kStandardSizes = {{
    {1920, 1080}, {1600, 1200}, {1280, 960}, {1280, 720}, {1024, 768}, {800, 600},
    {720, 480}, {640, 480}, {352, 288}, {320, 240}, {176, 144},
}};

constexpr std::array<int32_t, 3> kOutputFormats = {
    0x22,
    0x23,
    0x21,
};
constexpr int32_t kFormatBlob = 0x21;

// return the frame duration of a host mode
int64_t FrameDurationNs(const HostMode& m) {
  return kNsPerSecond * static_cast<int64_t>(m.fpsDen) / static_cast<int64_t>(m.fpsNum);
}

// return the rounded frame rate of a host mode
int32_t RoundFps(const HostMode& m) {
  return std::max<int32_t>(1, static_cast<int32_t>((m.fpsNum + m.fpsDen / 2) / m.fpsDen));
}

// return true when a mode crops and scales to a size
bool Covers(const HostMode& m, int32_t width, int32_t height) {
  return static_cast<int32_t>(m.width) >= width && static_cast<int32_t>(m.height) >= height;
}

// return an even same-aspect thumbnail size near area
std::array<int32_t, 2> ThumbnailNear(int32_t width, int32_t height, int32_t area) {
  int32_t g = std::gcd(width, height);
  int32_t p = width / g, q = height / g;
  int32_t k = static_cast<int32_t>(std::sqrt(static_cast<double>(area) / (static_cast<double>(p) * q)));
  if (k >= 1 && ((p * k) % 2 != 0 || (q * k) % 2 != 0)) k--;
  if (k >= 2) return {p * k, q * k};
  int32_t tw = static_cast<int32_t>(std::sqrt(static_cast<double>(area) * width / height)) & ~1;
  int32_t th = std::max(2, static_cast<int32_t>(static_cast<int64_t>(tw) * height / width) & ~1);
  return {std::max(tw, 2), th};
}

// find a single byte value
bool FindU8(const camera_metadata_t* s, uint32_t tag, uint8_t* out) {
  camera_metadata_ro_entry_t e;
  if (s == nullptr || find_camera_metadata_ro_entry(s, tag, &e) != 0) return false;
  if (e.type != TYPE_BYTE || e.count != 1) return false;
  *out = e.data.u8[0];
  return true;
}

// find n int32 values
bool FindI32(const camera_metadata_t* s, uint32_t tag, int32_t* out, size_t n) {
  camera_metadata_ro_entry_t e;
  if (s == nullptr || find_camera_metadata_ro_entry(s, tag, &e) != 0) return false;
  if (e.type != TYPE_INT32 || e.count != n) return false;
  memcpy(out, e.data.i32, n * sizeof(int32_t));
  return true;
}

// a byte control and its allowed values
struct ByteControl {
  uint32_t tag;
  std::vector<uint8_t> allowed;
};

// return the byte controls and their supported values
const std::vector<ByteControl>& ByteControls() {
  static const std::vector<ByteControl> kControls = {
      {ANDROID_COLOR_CORRECTION_ABERRATION_MODE, {ANDROID_COLOR_CORRECTION_ABERRATION_MODE_OFF}},
      {ANDROID_CONTROL_AE_ANTIBANDING_MODE, {ANDROID_CONTROL_AE_ANTIBANDING_MODE_AUTO}},
      {ANDROID_CONTROL_AE_LOCK, {ANDROID_CONTROL_AE_LOCK_OFF}},
      {ANDROID_CONTROL_AE_MODE, {ANDROID_CONTROL_AE_MODE_ON}},
      {ANDROID_CONTROL_AE_PRECAPTURE_TRIGGER,
       {ANDROID_CONTROL_AE_PRECAPTURE_TRIGGER_IDLE, ANDROID_CONTROL_AE_PRECAPTURE_TRIGGER_START,
        ANDROID_CONTROL_AE_PRECAPTURE_TRIGGER_CANCEL}},
      {ANDROID_CONTROL_AF_MODE, {ANDROID_CONTROL_AF_MODE_OFF}},
      {ANDROID_CONTROL_AF_TRIGGER,
       {ANDROID_CONTROL_AF_TRIGGER_IDLE, ANDROID_CONTROL_AF_TRIGGER_START, ANDROID_CONTROL_AF_TRIGGER_CANCEL}},
      {ANDROID_CONTROL_AWB_LOCK, {ANDROID_CONTROL_AWB_LOCK_OFF}},
      {ANDROID_CONTROL_AWB_MODE, {ANDROID_CONTROL_AWB_MODE_AUTO}},
      {ANDROID_CONTROL_EFFECT_MODE, {ANDROID_CONTROL_EFFECT_MODE_OFF}},
      {ANDROID_CONTROL_MODE, {ANDROID_CONTROL_MODE_AUTO, ANDROID_CONTROL_MODE_OFF}},
      {ANDROID_CONTROL_SCENE_MODE, {ANDROID_CONTROL_SCENE_MODE_DISABLED}},
      {ANDROID_CONTROL_VIDEO_STABILIZATION_MODE, {ANDROID_CONTROL_VIDEO_STABILIZATION_MODE_OFF}},
      {ANDROID_FLASH_MODE, {ANDROID_FLASH_MODE_OFF}},
      {ANDROID_LENS_OPTICAL_STABILIZATION_MODE, {ANDROID_LENS_OPTICAL_STABILIZATION_MODE_OFF}},
      {ANDROID_NOISE_REDUCTION_MODE, {ANDROID_NOISE_REDUCTION_MODE_OFF}},
      {ANDROID_STATISTICS_FACE_DETECT_MODE, {ANDROID_STATISTICS_FACE_DETECT_MODE_OFF}},
      {ANDROID_STATISTICS_HOT_PIXEL_MAP_MODE, {ANDROID_STATISTICS_HOT_PIXEL_MAP_MODE_OFF}},
      {ANDROID_STATISTICS_LENS_SHADING_MAP_MODE, {ANDROID_STATISTICS_LENS_SHADING_MAP_MODE_OFF}},
  };
  return kControls;
}

// return the capture intent of a request template
bool IntentFor(int32_t requestTemplate, uint8_t* intent) {
  switch (requestTemplate) {
    case 1: *intent = ANDROID_CONTROL_CAPTURE_INTENT_PREVIEW; return true;
    case 2: *intent = ANDROID_CONTROL_CAPTURE_INTENT_STILL_CAPTURE; return true;
    case 3: *intent = ANDROID_CONTROL_CAPTURE_INTENT_VIDEO_RECORD; return true;
    case 4: *intent = ANDROID_CONTROL_CAPTURE_INTENT_VIDEO_SNAPSHOT; return true;
    default: return false;
  }
}

// return true when the shape lists a frame rate range
bool HasFpsRange(const CameraShape& shape, const int32_t range[2]) {
  for (const auto& r : shape.fpsRanges) {
    if (r[0] == range[0] && r[1] == range[1]) return true;
  }
  return false;
}

// return the largest thumbnail size
std::array<int32_t, 2> DefaultThumbnail(const CameraShape& shape) {
  return shape.thumbnailSizes.empty() ? std::array<int32_t, 2>{0, 0} : shape.thumbnailSizes.back();
}

// write the controls with a template's defaults
void AddDefaultControls(MetadataBuilder& md, const CameraShape& shape, uint8_t intent) {
  for (const ByteControl& c : ByteControls()) md.setU8(c.tag, {c.allowed[0]});
  md.setU8(ANDROID_CONTROL_CAPTURE_INTENT, {intent});
  md.setI32(ANDROID_CONTROL_AE_EXPOSURE_COMPENSATION, {0});
  bool video = intent == ANDROID_CONTROL_CAPTURE_INTENT_VIDEO_RECORD ||
               intent == ANDROID_CONTROL_CAPTURE_INTENT_VIDEO_SNAPSHOT;
  const auto& fps = video ? shape.recordFps : shape.previewFps;
  md.setI32(ANDROID_CONTROL_AE_TARGET_FPS_RANGE, {fps[0], fps[1]});
  md.setU8(ANDROID_JPEG_QUALITY, {static_cast<uint8_t>(kDefaultJpegQuality)});
  md.setU8(ANDROID_JPEG_THUMBNAIL_QUALITY, {static_cast<uint8_t>(kDefaultJpegQuality)});
  md.setI32(ANDROID_JPEG_ORIENTATION, {0});
  auto thumb = DefaultThumbnail(shape);
  md.setI32(ANDROID_JPEG_THUMBNAIL_SIZE, {thumb[0], thumb[1]});
  md.setI32(ANDROID_SCALER_CROP_REGION, {0, 0, shape.arrayWidth, shape.arrayHeight});
  md.setI32(ANDROID_SENSOR_TEST_PATTERN_MODE, {ANDROID_SENSOR_TEST_PATTERN_MODE_OFF});
}

// echo the request controls within the supported values
void EchoControls(MetadataBuilder& md, const CameraShape& shape, const camera_metadata_t* s) {
  for (const ByteControl& c : ByteControls()) {
    uint8_t v = c.allowed[0];
    uint8_t asked;
    if (FindU8(s, c.tag, &asked) && std::find(c.allowed.begin(), c.allowed.end(), asked) != c.allowed.end()) {
      v = asked;
    }
    md.setU8(c.tag, {v});
  }
  uint8_t intent = ANDROID_CONTROL_CAPTURE_INTENT_PREVIEW;
  uint8_t askedIntent;
  if (FindU8(s, ANDROID_CONTROL_CAPTURE_INTENT, &askedIntent) &&
      askedIntent <= ANDROID_CONTROL_CAPTURE_INTENT_MOTION_TRACKING) {
    intent = askedIntent;
  }
  md.setU8(ANDROID_CONTROL_CAPTURE_INTENT, {intent});
  md.setI32(ANDROID_CONTROL_AE_EXPOSURE_COMPENSATION, {0});
  int32_t fps[2] = {shape.previewFps[0], shape.previewFps[1]};
  int32_t askedFps[2];
  if (FindI32(s, ANDROID_CONTROL_AE_TARGET_FPS_RANGE, askedFps, 2) && HasFpsRange(shape, askedFps)) {
    fps[0] = askedFps[0];
    fps[1] = askedFps[1];
  }
  md.setI32(ANDROID_CONTROL_AE_TARGET_FPS_RANGE, {fps[0], fps[1]});
  JpegSettings jpeg = JpegSettingsFrom(shape, s);
  md.setU8(ANDROID_JPEG_QUALITY, {static_cast<uint8_t>(jpeg.quality)});
  md.setU8(ANDROID_JPEG_THUMBNAIL_QUALITY, {static_cast<uint8_t>(jpeg.thumbnailQuality)});
  md.setI32(ANDROID_JPEG_ORIENTATION, {jpeg.orientation});
  md.setI32(ANDROID_JPEG_THUMBNAIL_SIZE, {jpeg.thumbnailWidth, jpeg.thumbnailHeight});
  md.setI32(ANDROID_SCALER_CROP_REGION, {0, 0, shape.arrayWidth, shape.arrayHeight});
  md.setI32(ANDROID_SENSOR_TEST_PATTERN_MODE, {ANDROID_SENSOR_TEST_PATTERN_MODE_OFF});
}

// add the result keys
void AddDynamicResults(MetadataBuilder& md, const camera_metadata_t* s, int64_t timestampNs,
                       int32_t pipelineDepth) {
  uint8_t controlMode = ANDROID_CONTROL_MODE_AUTO;
  uint8_t asked;
  if (FindU8(s, ANDROID_CONTROL_MODE, &asked) && asked == ANDROID_CONTROL_MODE_OFF) controlMode = asked;
  bool auto3a = controlMode == ANDROID_CONTROL_MODE_AUTO;
  md.setU8(ANDROID_CONTROL_AE_STATE,
           {auto3a ? uint8_t(ANDROID_CONTROL_AE_STATE_CONVERGED) : uint8_t(ANDROID_CONTROL_AE_STATE_INACTIVE)});
  md.setU8(ANDROID_CONTROL_AWB_STATE,
           {auto3a ? uint8_t(ANDROID_CONTROL_AWB_STATE_CONVERGED) : uint8_t(ANDROID_CONTROL_AWB_STATE_INACTIVE)});
  md.setU8(ANDROID_CONTROL_AF_STATE, {ANDROID_CONTROL_AF_STATE_INACTIVE});
  md.setU8(ANDROID_FLASH_STATE, {ANDROID_FLASH_STATE_UNAVAILABLE});
  md.setU8(ANDROID_LENS_STATE, {ANDROID_LENS_STATE_STATIONARY});
  md.setU8(ANDROID_REQUEST_PIPELINE_DEPTH,
           {static_cast<uint8_t>(std::clamp(pipelineDepth, 1, static_cast<int32_t>(kPipelineMaxDepth)))});
  md.setI64(ANDROID_SENSOR_TIMESTAMP, {timestampNs});
  md.setU8(ANDROID_STATISTICS_SCENE_FLICKER, {ANDROID_STATISTICS_SCENE_FLICKER_NONE});
}

// add the stream configuration, minimum duration and stall duration lists
void AddStreamConfigurations(MetadataBuilder& md, const CameraShape& shape) {
  std::vector<int32_t> configs;
  std::vector<int64_t> durations;
  std::vector<int64_t> stalls;
  for (const OutputSize& s : shape.sizes) {
    for (int32_t f : kOutputFormats) {
      configs.insert(configs.end(),
                     {f, s.width, s.height, ANDROID_SCALER_AVAILABLE_STREAM_CONFIGURATIONS_OUTPUT});
      durations.insert(durations.end(), {f, s.width, s.height, s.minFrameDurationNs});
      int64_t stall = f == kFormatBlob ? s.minFrameDurationNs + int64_t(s.width) * s.height * 25 : 0;
      stalls.insert(stalls.end(), {f, s.width, s.height, stall});
    }
  }
  md.setI32(ANDROID_SCALER_AVAILABLE_STREAM_CONFIGURATIONS, configs);
  md.setI64(ANDROID_SCALER_AVAILABLE_MIN_FRAME_DURATIONS, durations);
  md.setI64(ANDROID_SCALER_AVAILABLE_STALL_DURATIONS, stalls);
}

// return the keys of a default template
std::vector<int32_t> RequestKeys(const CameraShape& shape) {
  MetadataBuilder md;
  AddDefaultControls(md, shape, ANDROID_CONTROL_CAPTURE_INTENT_PREVIEW);
  return md.tags();
}

// return the result keys
std::vector<int32_t> ResultKeys(const CameraShape& shape) {
  MetadataBuilder md;
  EchoControls(md, shape, nullptr);
  AddDynamicResults(md, nullptr, 0, 1);
  return md.tags();
}

}

std::vector<int32_t> MetadataBuilder::tags() const {
  std::vector<int32_t> out;
  for (const auto& [tag, e] : entries_) out.push_back(static_cast<int32_t>(tag));
  return out;
}

bool MetadataBuilder::set(uint32_t tag, uint8_t type, const void* data, size_t count) {
  int want = get_camera_metadata_tag_type(tag);
  if (want != type) {
    klogf("metadata tag 0x%x wants type %d, given %d; dropped", tag, want, type);
    return false;
  }
  Entry e{type, count, {}};
  size_t bytes = count * camera_metadata_type_size[type];
  e.bytes.assign(static_cast<const uint8_t*>(data), static_cast<const uint8_t*>(data) + bytes);
  entries_[tag] = std::move(e);
  return true;
}

// return the sorted blob, or empty
std::vector<uint8_t> MetadataBuilder::finish() const {
  size_t dataSize = 0;
  for (const auto& [tag, e] : entries_) dataSize += calculate_camera_metadata_entry_data_size(e.type, e.count);
  camera_metadata_t* m = allocate_camera_metadata(entries_.size(), dataSize);
  if (m == nullptr) return {};
  for (const auto& [tag, e] : entries_) {
    if (add_camera_metadata_entry(m, tag, e.bytes.data(), e.count) != 0) {
      klogf("metadata tag 0x%x could not be added", tag);
      free_camera_metadata(m);
      return {};
    }
  }
  sort_camera_metadata(m);
  const auto* raw = reinterpret_cast<const uint8_t*>(m);
  std::vector<uint8_t> out(raw, raw + get_camera_metadata_size(m));
  free_camera_metadata(m);
  return out;
}

void MetadataDeleter::operator()(camera_metadata_t* m) const { free(m); }

// copy a metadata blob, or return null when malformed or empty
MetadataPtr ParseMetadata(const std::vector<uint8_t>& blob) {
  if (blob.size() < sizeof(uint32_t) * 12) return nullptr;
  void* p = malloc(blob.size());
  if (p == nullptr) return nullptr;
  memcpy(p, blob.data(), blob.size());
  size_t expected = blob.size();
  if (validate_camera_metadata_structure(static_cast<camera_metadata_t*>(p), &expected) != 0) {
    free(p);
    return nullptr;
  }
  return MetadataPtr(static_cast<camera_metadata_t*>(p));
}

// return true when a blob is well-formed and matches its size
bool ValidMetadataBlob(const std::vector<uint8_t>& blob) {
  MetadataPtr m = ParseMetadata(blob);
  return m != nullptr && get_camera_metadata_size(m.get()) == blob.size();
}

// return the output sizes, frame rates and JPEG bounds of host modes
CameraShape ShapeFor(const std::vector<HostMode>& modes) {
  CameraShape shape;
  if (modes.empty()) return shape;
  const HostMode* largest = &modes[0];
  for (const HostMode& m : modes) {
    uint64_t a = uint64_t(m.width) * m.height, b = uint64_t(largest->width) * largest->height;
    if (a > b || (a == b && FrameDurationNs(m) < FrameDurationNs(*largest))) largest = &m;
  }
  shape.arrayWidth = static_cast<int32_t>(largest->width);
  shape.arrayHeight = static_cast<int32_t>(largest->height);

  std::set<std::pair<int32_t, int32_t>> sizes;
  for (const HostMode& m : modes) sizes.insert({int32_t(m.width), int32_t(m.height)});
  for (const auto& s : kStandardSizes) {
    for (const HostMode& m : modes) {
      if (Covers(m, s[0], s[1])) {
        sizes.insert({s[0], s[1]});
        break;
      }
    }
  }
  int64_t slowestSize = 0;
  for (const auto& [w, h] : sizes) {
    int64_t best = INT64_MAX;
    for (const HostMode& m : modes) {
      if (Covers(m, w, h)) best = std::min(best, FrameDurationNs(m));
    }
    shape.sizes.push_back(OutputSize{w, h, best});
    slowestSize = std::max(slowestSize, best);
  }
  std::sort(shape.sizes.begin(), shape.sizes.end(), [](const OutputSize& a, const OutputSize& b) {
    int64_t aa = int64_t(a.width) * a.height, ba = int64_t(b.width) * b.height;
    return aa != ba ? aa > ba : a.width > b.width;
  });

  std::set<int32_t> rates;
  for (const HostMode& m : modes) rates.insert(RoundFps(m));
  int32_t fastest = *rates.rbegin();
  std::set<std::array<int32_t, 2>> ranges;
  for (int32_t f : rates) {
    ranges.insert({f, f});
    if (f > kVariableFpsFloor) ranges.insert({kVariableFpsFloor, f});
  }
  for (int32_t f : kPacedRates) {
    if (f <= fastest) ranges.insert({f, f});
  }
  if (fastest >= kDefaultMaxFps) ranges.insert({kVariableFpsFloor, kDefaultMaxFps});
  shape.fpsRanges.assign(ranges.begin(), ranges.end());
  int32_t pick = *rates.begin();
  for (int32_t f : rates) {
    if (f <= kDefaultMaxFps) pick = f;
  }
  if (fastest >= kDefaultMaxFps) pick = kDefaultMaxFps;
  shape.recordFps = {pick, pick};
  shape.previewFps = pick > kVariableFpsFloor ? std::array<int32_t, 2>{kVariableFpsFloor, pick}
                                              : std::array<int32_t, 2>{pick, pick};
  int32_t slowestFps = shape.fpsRanges.front()[0];
  for (const auto& r : shape.fpsRanges) slowestFps = std::min(slowestFps, r[0]);
  shape.maxFrameDurationNs = std::max(kNsPerSecond / slowestFps, slowestSize);

  auto arrayThumb = ThumbnailNear(shape.arrayWidth, shape.arrayHeight, kArrayThumbnailArea);
  int32_t arrayThumbArea = arrayThumb[0] * arrayThumb[1];
  std::set<std::array<int32_t, 2>> thumbs = {arrayThumb};
  for (const OutputSize& s : shape.sizes) {
    if (int64_t(s.width) * shape.arrayHeight == int64_t(s.height) * shape.arrayWidth) continue;
    auto t = ThumbnailNear(s.width, s.height, arrayThumbArea * 3 / 4);
    if (t[0] * t[1] >= arrayThumbArea) t = ThumbnailNear(s.width, s.height, arrayThumbArea / 2);
    thumbs.insert(t);
  }
  shape.thumbnailSizes.assign(thumbs.begin(), thumbs.end());
  std::sort(shape.thumbnailSizes.begin(), shape.thumbnailSizes.end(),
            [](const std::array<int32_t, 2>& a, const std::array<int32_t, 2>& b) {
              int32_t aa = a[0] * a[1], ba = b[0] * b[1];
              return aa != ba ? aa < ba : a[0] < b[0];
            });
  shape.thumbnailSizes.insert(shape.thumbnailSizes.begin(), std::array<int32_t, 2>{0, 0});

  int64_t jpeg = int64_t(shape.arrayWidth) * shape.arrayHeight * 2 + kJpegHeadroom;
  shape.jpegMaxSize = static_cast<int32_t>(std::max<int64_t>(jpeg, kJpegMinMaxSize));
  return shape;
}

// return true when the shape lists a size
bool ShapeHasSize(const CameraShape& shape, int32_t width, int32_t height) {
  for (const OutputSize& s : shape.sizes) {
    if (s.width == width && s.height == height) return true;
  }
  return false;
}

// return the slowest mode of the best size reaching maxFps
int ChooseMode(const std::vector<HostMode>& modes, int32_t width, int32_t height, int32_t maxFps) {
  int bySize = ChooseModeBySize(modes, width, height);
  if (bySize < 0 || maxFps <= 0) return bySize;
  const HostMode& size = modes[static_cast<size_t>(bySize)];
  int slowestEnough = -1, fastest = bySize;
  for (size_t i = 0; i < modes.size(); i++) {
    const HostMode& m = modes[i];
    if (m.width != size.width || m.height != size.height) continue;
    if (FrameDurationNs(m) < FrameDurationNs(modes[static_cast<size_t>(fastest)])) fastest = static_cast<int>(i);
    if (RoundFps(m) >= maxFps &&
        (slowestEnough < 0 || FrameDurationNs(m) > FrameDurationNs(modes[static_cast<size_t>(slowestEnough)]))) {
      slowestEnough = static_cast<int>(i);
    }
  }
  return slowestEnough >= 0 ? slowestEnough : fastest;
}

// return the mode best covering a size, or -1 with no modes
int ChooseModeBySize(const std::vector<HostMode>& modes, int32_t width, int32_t height) {
  int best = -1;
  bool bestCovers = false;
  double bestAspectErr = 0, bestCrop = 0;
  uint64_t bestArea = 0;
  int64_t bestDuration = 0;
  for (size_t i = 0; i < modes.size(); i++) {
    const HostMode& m = modes[i];
    bool covers = Covers(m, width, height);
    double mAspect = double(m.width) / m.height, want = double(width) / height;
    double aspectErr = std::fabs(mAspect - want) / want;
    double crop = std::min<double>(m.width, m.height * want) * std::min<double>(m.height, m.width / want);
    uint64_t area = uint64_t(m.width) * m.height;
    int64_t duration = FrameDurationNs(m);
    bool better;
    if (best < 0) {
      better = true;
    } else if (covers != bestCovers) {
      better = covers;
    } else if (covers) {
      bool close = aspectErr < 0.01, bestClose = bestAspectErr < 0.01;
      if (close != bestClose) better = close;
      else if (!close && std::fabs(aspectErr - bestAspectErr) > 1e-9) better = aspectErr < bestAspectErr;
      else if (area != bestArea) better = area < bestArea;
      else better = duration < bestDuration;
    } else {
      if (std::fabs(crop - bestCrop) > 0.5) better = crop > bestCrop;
      else better = duration < bestDuration;
    }
    if (better) {
      best = static_cast<int>(i);
      bestCovers = covers;
      bestAspectErr = aspectErr;
      bestCrop = crop;
      bestArea = area;
      bestDuration = duration;
    }
  }
  return best;
}

// build the static characteristics blob
std::vector<uint8_t> BuildCharacteristics(const CameraShape& shape) {
  MetadataBuilder md;
  md.setU8(ANDROID_INFO_SUPPORTED_HARDWARE_LEVEL, {ANDROID_INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL});
  md.setU8(ANDROID_LENS_FACING, {ANDROID_LENS_FACING_EXTERNAL});
  md.setU8(ANDROID_REQUEST_AVAILABLE_CAPABILITIES, {ANDROID_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE});

  md.setU8(ANDROID_COLOR_CORRECTION_AVAILABLE_ABERRATION_MODES, {ANDROID_COLOR_CORRECTION_ABERRATION_MODE_OFF});
  md.setU8(ANDROID_CONTROL_AE_AVAILABLE_ANTIBANDING_MODES, {ANDROID_CONTROL_AE_ANTIBANDING_MODE_AUTO});
  md.setU8(ANDROID_CONTROL_AE_AVAILABLE_MODES, {ANDROID_CONTROL_AE_MODE_ON});
  std::vector<int32_t> fps;
  for (const auto& r : shape.fpsRanges) fps.insert(fps.end(), {r[0], r[1]});
  md.setI32(ANDROID_CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES, fps);
  md.setI32(ANDROID_CONTROL_AE_COMPENSATION_RANGE, {0, 0});
  md.setRational(ANDROID_CONTROL_AE_COMPENSATION_STEP, {{1, 6}});
  md.setU8(ANDROID_CONTROL_AE_LOCK_AVAILABLE, {ANDROID_CONTROL_AE_LOCK_AVAILABLE_FALSE});
  md.setU8(ANDROID_CONTROL_AF_AVAILABLE_MODES, {ANDROID_CONTROL_AF_MODE_OFF});
  md.setU8(ANDROID_CONTROL_AVAILABLE_EFFECTS, {ANDROID_CONTROL_EFFECT_MODE_OFF});
  md.setU8(ANDROID_CONTROL_AVAILABLE_MODES, {ANDROID_CONTROL_MODE_OFF, ANDROID_CONTROL_MODE_AUTO});
  md.setU8(ANDROID_CONTROL_AVAILABLE_SCENE_MODES, {ANDROID_CONTROL_SCENE_MODE_DISABLED});
  md.setU8(ANDROID_CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES, {ANDROID_CONTROL_VIDEO_STABILIZATION_MODE_OFF});
  md.setU8(ANDROID_CONTROL_AWB_AVAILABLE_MODES, {ANDROID_CONTROL_AWB_MODE_AUTO});
  md.setU8(ANDROID_CONTROL_AWB_LOCK_AVAILABLE, {ANDROID_CONTROL_AWB_LOCK_AVAILABLE_FALSE});
  md.setI32(ANDROID_CONTROL_MAX_REGIONS, {0, 0, 0});
  md.setU8(ANDROID_EDGE_AVAILABLE_EDGE_MODES, {ANDROID_EDGE_MODE_OFF});
  md.setU8(ANDROID_FLASH_INFO_AVAILABLE, {ANDROID_FLASH_INFO_AVAILABLE_FALSE});
  md.setU8(ANDROID_HOT_PIXEL_AVAILABLE_HOT_PIXEL_MODES, {ANDROID_HOT_PIXEL_MODE_OFF});

  std::vector<int32_t> thumbs;
  for (const auto& t : shape.thumbnailSizes) thumbs.insert(thumbs.end(), {t[0], t[1]});
  md.setI32(ANDROID_JPEG_AVAILABLE_THUMBNAIL_SIZES, thumbs);
  md.setI32(ANDROID_JPEG_MAX_SIZE, {shape.jpegMaxSize});

  md.setU8(ANDROID_LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION, {ANDROID_LENS_OPTICAL_STABILIZATION_MODE_OFF});
  md.setU8(ANDROID_LENS_INFO_FOCUS_DISTANCE_CALIBRATION, {ANDROID_LENS_INFO_FOCUS_DISTANCE_CALIBRATION_UNCALIBRATED});
  md.setFloat(ANDROID_LENS_INFO_MINIMUM_FOCUS_DISTANCE, {0.0f});
  md.setU8(ANDROID_NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES, {ANDROID_NOISE_REDUCTION_MODE_OFF});

  md.setI32(ANDROID_REQUEST_MAX_NUM_OUTPUT_STREAMS, {0, kMaxProcessedStreams, kMaxStallStreams});
  md.setI32(ANDROID_REQUEST_MAX_NUM_INPUT_STREAMS, {0});
  md.setI32(ANDROID_REQUEST_PARTIAL_RESULT_COUNT, {1});
  md.setU8(ANDROID_REQUEST_PIPELINE_MAX_DEPTH, {static_cast<uint8_t>(kPipelineMaxDepth)});

  md.setFloat(ANDROID_SCALER_AVAILABLE_MAX_DIGITAL_ZOOM, {1.0f});
  md.setU8(ANDROID_SCALER_CROPPING_TYPE, {ANDROID_SCALER_CROPPING_TYPE_CENTER_ONLY});
  AddStreamConfigurations(md, shape);

  md.setI32(ANDROID_SENSOR_AVAILABLE_TEST_PATTERN_MODES, {ANDROID_SENSOR_TEST_PATTERN_MODE_OFF});
  md.setI32(ANDROID_SENSOR_INFO_ACTIVE_ARRAY_SIZE, {0, 0, shape.arrayWidth, shape.arrayHeight});
  md.setI32(ANDROID_SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE, {0, 0, shape.arrayWidth, shape.arrayHeight});
  md.setI32(ANDROID_SENSOR_INFO_PIXEL_ARRAY_SIZE, {shape.arrayWidth, shape.arrayHeight});
  md.setI64(ANDROID_SENSOR_INFO_MAX_FRAME_DURATION, {shape.maxFrameDurationNs});
  md.setU8(ANDROID_SENSOR_INFO_TIMESTAMP_SOURCE, {ANDROID_SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN});
  md.setI32(ANDROID_SENSOR_ORIENTATION, {0});
  md.setU8(ANDROID_SENSOR_READOUT_TIMESTAMP, {ANDROID_SENSOR_READOUT_TIMESTAMP_NOT_SUPPORTED});
  md.setU8(ANDROID_SHADING_AVAILABLE_MODES, {ANDROID_SHADING_MODE_OFF});

  md.setU8(ANDROID_STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES, {ANDROID_STATISTICS_FACE_DETECT_MODE_OFF});
  md.setU8(ANDROID_STATISTICS_INFO_AVAILABLE_HOT_PIXEL_MAP_MODES, {ANDROID_STATISTICS_HOT_PIXEL_MAP_MODE_OFF});
  md.setU8(ANDROID_STATISTICS_INFO_AVAILABLE_LENS_SHADING_MAP_MODES, {ANDROID_STATISTICS_LENS_SHADING_MAP_MODE_OFF});
  md.setI32(ANDROID_STATISTICS_INFO_MAX_FACE_COUNT, {0});
  md.setI32(ANDROID_SYNC_MAX_LATENCY, {ANDROID_SYNC_MAX_LATENCY_UNKNOWN});

  md.setI32(ANDROID_REQUEST_AVAILABLE_REQUEST_KEYS, RequestKeys(shape));
  md.setI32(ANDROID_REQUEST_AVAILABLE_RESULT_KEYS, ResultKeys(shape));
  std::vector<int32_t> chars;
  for (int32_t tag : md.tags()) {
    if (tag != ANDROID_REQUEST_AVAILABLE_REQUEST_KEYS && tag != ANDROID_REQUEST_AVAILABLE_RESULT_KEYS) {
      chars.push_back(tag);
    }
  }
  md.setI32(ANDROID_REQUEST_AVAILABLE_CHARACTERISTICS_KEYS, chars);
  return md.finish();
}

// build a request template, or empty when unsupported
std::vector<uint8_t> BuildDefaultRequest(const CameraShape& shape, int32_t requestTemplate) {
  uint8_t intent;
  if (!IntentFor(requestTemplate, &intent)) return {};
  MetadataBuilder md;
  AddDefaultControls(md, shape, intent);
  return md.finish();
}

// build the session characteristics
std::vector<uint8_t> BuildSessionCharacteristics() {
  MetadataBuilder md;
  md.setFloat(ANDROID_CONTROL_ZOOM_RATIO_RANGE, {1.0f, 1.0f});
  md.setFloat(ANDROID_SCALER_AVAILABLE_MAX_DIGITAL_ZOOM, {1.0f});
  return md.finish();
}

// build the result metadata of a completed request
std::vector<uint8_t> BuildResult(const CameraShape& shape, const camera_metadata_t* settings,
                                 int64_t timestampNs, int32_t pipelineDepth) {
  MetadataBuilder md;
  EchoControls(md, shape, settings);
  AddDynamicResults(md, settings, timestampNs, pipelineDepth);
  return md.finish();
}

// return the upper end of a request's AE target range
int32_t RequestedMaxFps(const CameraShape& shape, const camera_metadata_t* settings) {
  int32_t asked[2];
  if (FindI32(settings, ANDROID_CONTROL_AE_TARGET_FPS_RANGE, asked, 2) && HasFpsRange(shape, asked)) return asked[1];
  return shape.previewFps[1];
}

// read a request's JPEG settings within the shape's limits
JpegSettings JpegSettingsFrom(const CameraShape& shape, const camera_metadata_t* settings) {
  JpegSettings j;
  auto thumb = DefaultThumbnail(shape);
  j.thumbnailWidth = thumb[0];
  j.thumbnailHeight = thumb[1];
  uint8_t q;
  if (FindU8(settings, ANDROID_JPEG_QUALITY, &q) && q >= 1 && q <= 100) j.quality = q;
  if (FindU8(settings, ANDROID_JPEG_THUMBNAIL_QUALITY, &q) && q >= 1 && q <= 100) j.thumbnailQuality = q;
  int32_t orientation;
  if (FindI32(settings, ANDROID_JPEG_ORIENTATION, &orientation, 1) && orientation % 90 == 0) {
    j.orientation = ((orientation % 360) + 360) % 360;
  }
  int32_t size[2];
  if (FindI32(settings, ANDROID_JPEG_THUMBNAIL_SIZE, size, 2)) {
    for (const auto& t : shape.thumbnailSizes) {
      if (t[0] == size[0] && t[1] == size[1]) {
        j.thumbnailWidth = size[0];
        j.thumbnailHeight = size[1];
      }
    }
  }
  return j;
}

}

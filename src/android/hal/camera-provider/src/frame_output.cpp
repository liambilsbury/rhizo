#include "frame_output.h"

#include <string.h>

#include <algorithm>

namespace rhizo::camera {

namespace {

constexpr uint16_t kTypeShort = 3;
constexpr uint16_t kTypeLong = 4;
constexpr uint16_t kTypeAscii = 2;
constexpr uint16_t kTypeRational = 5;
constexpr uint16_t kTypeUndefined = 7;
constexpr size_t kMaxApp1Payload = 65535 - 2;
constexpr int32_t kMinJpegQuality = 40;
constexpr int32_t kQualityStep = 15;

// a TIFF directory entry and its value bytes
struct IfdEntry {
  uint16_t tag;
  uint16_t type;
  uint32_t count;
  std::vector<uint8_t> value;
};

void PutU16(std::vector<uint8_t>& v, size_t at, uint16_t x) {
  v[at] = static_cast<uint8_t>(x);
  v[at + 1] = static_cast<uint8_t>(x >> 8);
}

void PutU32(std::vector<uint8_t>& v, size_t at, uint32_t x) {
  for (int i = 0; i < 4; i++) v[at + i] = static_cast<uint8_t>(x >> (8 * i));
}

std::vector<uint8_t> LeU32(uint32_t x) {
  return {static_cast<uint8_t>(x), static_cast<uint8_t>(x >> 8), static_cast<uint8_t>(x >> 16),
          static_cast<uint8_t>(x >> 24)};
}

IfdEntry Ascii(uint16_t tag, const std::string& s) {
  std::vector<uint8_t> v(s.begin(), s.end());
  v.push_back(0);
  return {tag, kTypeAscii, static_cast<uint32_t>(v.size()), v};
}

IfdEntry Short(uint16_t tag, uint16_t x) {
  return {tag, kTypeShort, 1, {static_cast<uint8_t>(x), static_cast<uint8_t>(x >> 8)}};
}

IfdEntry Long(uint16_t tag, uint32_t x) { return {tag, kTypeLong, 1, LeU32(x)}; }

IfdEntry Rational(uint16_t tag, uint32_t num, uint32_t den) {
  std::vector<uint8_t> v = LeU32(num);
  std::vector<uint8_t> d = LeU32(den);
  v.insert(v.end(), d.begin(), d.end());
  return {tag, kTypeRational, 1, v};
}

IfdEntry Undefined(uint16_t tag, const char (&bytes)[5]) {
  return {tag, kTypeUndefined, 4, std::vector<uint8_t>(bytes, bytes + 4)};
}

// return the size of an IFD with its out-of-line values
size_t IfdSize(const std::vector<IfdEntry>& entries) {
  size_t size = 2 + 12 * entries.size() + 4;
  for (const IfdEntry& e : entries) {
    if (e.value.size() > 4) size += (e.value.size() + 1) & ~size_t{1};
  }
  return size;
}

// write an IFD followed by its out-of-line values
void WriteIfd(std::vector<uint8_t>& tiff, size_t at, const std::vector<IfdEntry>& entries, uint32_t next) {
  size_t values = at + 2 + 12 * entries.size() + 4;
  PutU16(tiff, at, static_cast<uint16_t>(entries.size()));
  size_t pos = at + 2;
  for (const IfdEntry& e : entries) {
    PutU16(tiff, pos, e.tag);
    PutU16(tiff, pos + 2, e.type);
    PutU32(tiff, pos + 4, e.count);
    if (e.value.size() <= 4) {
      memcpy(&tiff[pos + 8], e.value.data(), e.value.size());
    } else {
      PutU32(tiff, pos + 8, static_cast<uint32_t>(values));
      memcpy(&tiff[values], e.value.data(), e.value.size());
      values += (e.value.size() + 1) & ~size_t{1};
    }
    pos += 12;
  }
  PutU32(tiff, pos, next);
}

// build the Exif TIFF, or empty when too large
std::vector<uint8_t> BuildTiff(const ExifInfo& info, const uint8_t* thumbnail, size_t thumbnailSize) {
  std::vector<IfdEntry> ifd0 = {
      Ascii(0x010F, info.make),
      Ascii(0x0110, info.model),
      Short(0x0112, ExifOrientation(info.orientation)),
      Rational(0x011A, 72, 1),
      Rational(0x011B, 72, 1),
      Short(0x0128, 2),
      Ascii(0x0132, info.dateTime),
      Short(0x0213, 1),
      Long(0x8769, 0),
  };
  std::vector<IfdEntry> exif = {
      Undefined(0x9000, "0232"),
      Ascii(0x9003, info.dateTime),
      Ascii(0x9004, info.dateTime),
      {0x9101, kTypeUndefined, 4, {1, 2, 3, 0}},
      Undefined(0xA000, "0100"),
      Short(0xA001, 1),
      Long(0xA002, static_cast<uint32_t>(info.width)),
      Long(0xA003, static_cast<uint32_t>(info.height)),
  };
  std::vector<IfdEntry> ifd1;
  if (thumbnail != nullptr && thumbnailSize > 0) {
    ifd1 = {
        Short(0x0103, 6),
        Rational(0x011A, 72, 1),
        Rational(0x011B, 72, 1),
        Short(0x0128, 2),
        Long(0x0201, 0),
        Long(0x0202, static_cast<uint32_t>(thumbnailSize)),
    };
  }
  size_t ifd0At = 8;
  size_t exifAt = ifd0At + IfdSize(ifd0);
  size_t ifd1At = exifAt + IfdSize(exif);
  size_t thumbAt = ifd1At + (ifd1.empty() ? 0 : IfdSize(ifd1));
  size_t total = thumbAt + (ifd1.empty() ? 0 : thumbnailSize);
  if (total + 6 > kMaxApp1Payload) return {};
  ifd0.back().value = LeU32(static_cast<uint32_t>(exifAt));
  if (!ifd1.empty()) ifd1[4].value = LeU32(static_cast<uint32_t>(thumbAt));

  std::vector<uint8_t> tiff(total, 0);
  tiff[0] = 'I';
  tiff[1] = 'I';
  PutU16(tiff, 2, 42);
  PutU32(tiff, 4, static_cast<uint32_t>(ifd0At));
  WriteIfd(tiff, ifd0At, ifd0, ifd1.empty() ? 0 : static_cast<uint32_t>(ifd1At));
  WriteIfd(tiff, exifAt, exif, 0);
  if (!ifd1.empty()) {
    WriteIfd(tiff, ifd1At, ifd1, 0);
    memcpy(&tiff[thumbAt], thumbnail, thumbnailSize);
  }
  return tiff;
}

// return the descending JPEG qualities from a requested quality
std::vector<int32_t> Qualities(int32_t asked) {
  std::vector<int32_t> out = {std::clamp(asked, 1, 100)};
  for (int32_t q = out[0] - kQualityStep; q >= kMinJpegQuality; q -= kQualityStep) out.push_back(q);
  return out;
}

// return a packed I420 view of w x h in v
I420View Packed(std::vector<uint8_t>& v, int32_t w, int32_t h) {
  v.resize(static_cast<size_t>(w) * h * 3 / 2);
  return I420View{v.data(), w, h};
}

}

// map a clockwise rotation to an Exif orientation
uint16_t ExifOrientation(int32_t degrees) {
  switch (((degrees % 360) + 360) % 360) {
    case 90: return 6;
    case 180: return 3;
    case 270: return 8;
    default: return 1;
  }
}

// build an Exif APP1 segment, or empty when it cannot fit
std::vector<uint8_t> BuildExifApp1(const ExifInfo& info, const uint8_t* thumbnail, size_t thumbnailSize) {
  std::vector<uint8_t> tiff = BuildTiff(info, thumbnail, thumbnailSize);
  if (tiff.empty()) return {};
  size_t length = 2 + 6 + tiff.size();
  std::vector<uint8_t> seg = {0xFF, 0xE1, static_cast<uint8_t>(length >> 8), static_cast<uint8_t>(length),
                              'E', 'x', 'i', 'f', 0, 0};
  seg.insert(seg.end(), tiff.begin(), tiff.end());
  return seg;
}

// write a JPEG with its CameraBlob trailer, or return -1
ssize_t WriteJpegBlob(const I420View& image, int quality, const std::vector<uint8_t>& app1, uint8_t* blob,
                      size_t blobSize) {
  size_t a = app1.size();
  if (blobSize < a + kCameraBlobSize + 4) return -1;
  uint8_t* dst = blob + a;
  ssize_t n = EncodeJpeg(image, quality, dst, blobSize - kCameraBlobSize - a);
  if (n < 4 || dst[0] != 0xFF || dst[1] != 0xD8) return -1;
  blob[0] = 0xFF;
  blob[1] = 0xD8;
  if (a > 0) memcpy(blob + 2, app1.data(), a);
  size_t total = a + static_cast<size_t>(n);
  int32_t trailer[2] = {kCameraBlobIdJpeg, static_cast<int32_t>(total)};
  memcpy(blob + blobSize - kCameraBlobSize, trailer, sizeof(trailer));
  return static_cast<ssize_t>(total);
}

// halve a crop of src until within twice dst's size
I420View StepDown(const I420View& src, Rect* crop, int32_t dstWidth, int32_t dstHeight, Scratch& s) {
  I420View view = src;
  bool intoA = true;
  while (crop->width > 2 * dstWidth || crop->height > 2 * dstHeight) {
    int32_t w = std::max(dstWidth, (crop->width / 2) & ~1);
    int32_t h = std::max(dstHeight, (crop->height / 2) & ~1);
    if (w < 2 || h < 2) break;
    std::vector<uint8_t>& buf = intoA ? s.a : s.b;
    I420View next = Packed(buf, w, h);
    ScaleI420ToPacked(view, *crop, buf.data(), w, h);
    view = next;
    *crop = Rect{0, 0, w, h};
    intoA = !intoA;
  }
  return view;
}

// centre-crop and scale a frame into a YUV buffer
void FillYuv(const I420View& frame, const YuvDest& dst, Scratch& s) {
  Rect crop = CenterCropFor(frame.width, frame.height, dst.width, dst.height);
  I420View view = StepDown(frame, &crop, dst.width, dst.height, s);
  ScaleI420(view, crop, dst);
}

// centre-crop and scale a frame into an RGBA buffer
void FillRgba(const I420View& frame, uint8_t* rgba, int32_t rowStrideBytes, int32_t width, int32_t height,
              Scratch& s) {
  Rect crop = CenterCropFor(frame.width, frame.height, width, height);
  I420View view = StepDown(frame, &crop, width, height, s);
  ScaleI420ToRgba(view, crop, rgba, rowStrideBytes, width, height);
}

// encode a frame as a JPEG blob, or return -1
ssize_t FillJpeg(const I420View& frame, int32_t width, int32_t height, const JpegRequest& req, uint8_t* blob,
                 size_t blobSize, Scratch& s) {
  std::vector<uint8_t> app1;
  ExifInfo exif = req.exif;
  exif.width = width;
  exif.height = height;
  if (req.thumbnailWidth > 0 && req.thumbnailHeight > 0) {
    Rect tcrop = CenterCropFor(frame.width, frame.height, req.thumbnailWidth, req.thumbnailHeight);
    I420View tview = StepDown(frame, &tcrop, req.thumbnailWidth, req.thumbnailHeight, s);
    I420View thumb = Packed(s.thumbnail, req.thumbnailWidth, req.thumbnailHeight);
    ScaleI420ToPacked(tview, tcrop, s.thumbnail.data(), req.thumbnailWidth, req.thumbnailHeight);
    s.thumbnailJpeg.resize(kMaxThumbnailBytes);
    for (int32_t q : Qualities(req.thumbnailQuality)) {
      ssize_t tn = EncodeJpeg(thumb, q, s.thumbnailJpeg.data(), s.thumbnailJpeg.size());
      if (tn > 0) app1 = BuildExifApp1(exif, s.thumbnailJpeg.data(), static_cast<size_t>(tn));
      if (!app1.empty()) break;
    }
  }
  if (app1.empty()) app1 = BuildExifApp1(exif, nullptr, 0);

  Rect crop = CenterCropFor(frame.width, frame.height, width, height);
  I420View view = StepDown(frame, &crop, width, height, s);
  I420View image = view;
  if (crop.left != 0 || crop.top != 0 || crop.width != width || crop.height != height ||
      view.width != width || view.height != height) {
    image = Packed(s.image, width, height);
    ScaleI420ToPacked(view, crop, s.image.data(), width, height);
  }
  for (int32_t q : Qualities(req.quality)) {
    ssize_t n = WriteJpegBlob(image, q, app1, blob, blobSize);
    if (n > 0) return n;
  }
  return -1;
}

}

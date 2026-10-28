#include "tools/measure/measure.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>

#include <algorithm>
#include <functional>
#include <map>
#include <memory>

#include "tools/streams.h"
#include "va/log.h"

namespace rhizo::c2va {

namespace {

double NowMs() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

const uint32_t kEncodeLadder[][2] = {{320, 240}, {720, 480}, {1280, 720}, {1920, 1080}, {3840, 2160}};
struct LadderSize {
  Codec codec;
  uint32_t width, height;
};
const LadderSize kDecodeLadder[] = {
    {Codec::kAvc, 320, 240},    {Codec::kAvc, 720, 480},    {Codec::kAvc, 1280, 720},   {Codec::kAvc, 1920, 1080},
    {Codec::kAvc, 3840, 2160},  {Codec::kHevc, 352, 288},   {Codec::kHevc, 640, 360},   {Codec::kHevc, 720, 480},
    {Codec::kHevc, 1280, 720},  {Codec::kHevc, 1920, 1080}, {Codec::kHevc, 3840, 2160}, {Codec::kVp9, 320, 180},
    {Codec::kVp9, 640, 360},    {Codec::kVp9, 1280, 720},   {Codec::kVp9, 1920, 1080},  {Codec::kVp9, 3840, 2160},
    {Codec::kAv1, 352, 288},    {Codec::kAv1, 640, 360},    {Codec::kAv1, 720, 480},    {Codec::kAv1, 1280, 720},
    {Codec::kAv1, 1920, 1080},  {Codec::kAv1, 3840, 2160},
};

struct ClipRate {
  Codec codec;
  uint32_t width, height, kbps;
};
const ClipRate kCtsRates[] = {
    {Codec::kAvc, 320, 240, 791},    {Codec::kAvc, 720, 480, 2045},    {Codec::kAvc, 1280, 720, 3098},
    {Codec::kAvc, 1920, 1080, 6232}, {Codec::kAvc, 3840, 2160, 17069}, {Codec::kHevc, 352, 288, 597},
    {Codec::kHevc, 640, 360, 1599},  {Codec::kHevc, 720, 480, 1010},   {Codec::kHevc, 1280, 720, 2002},
    {Codec::kHevc, 1920, 1080, 4988}, {Codec::kHevc, 3840, 2160, 14215}, {Codec::kVp9, 320, 180, 596},
    {Codec::kVp9, 640, 360, 1588},   {Codec::kVp9, 720, 480, 1172},    {Codec::kVp9, 1280, 720, 2301},
    {Codec::kVp9, 1920, 1080, 5242}, {Codec::kVp9, 3840, 2160, 15315}, {Codec::kAv1, 352, 288, 354},
    {Codec::kAv1, 640, 360, 651},    {Codec::kAv1, 720, 480, 1201},    {Codec::kAv1, 1280, 720, 2417},
    {Codec::kAv1, 1920, 1080, 5710}, {Codec::kAv1, 3840, 2160, 11900},
};

bool OnDecodeLadder(Codec codec, uint32_t w, uint32_t h) {
  for (const LadderSize& s : kDecodeLadder) {
    if (s.codec == codec && s.width == w && s.height == h) return true;
  }
  return false;
}

std::string SizeName(uint32_t w, uint32_t h) { return std::to_string(w) + "x" + std::to_string(h); }

const char* CodecName(Codec c) {
  switch (c) {
    case Codec::kAvc: return "avc";
    case Codec::kHevc: return "hevc";
    case Codec::kVp9: return "vp9";
    case Codec::kAv1: return "av1";
  }
  return "?";
}

void Json(std::string* out, const std::string& s) {
  *out += '"';
  for (char c : s) {
    if (c == '"' || c == '\\') {
      *out += '\\';
      *out += c;
    } else if (static_cast<unsigned char>(c) < 0x20) {
      char b[8];
      snprintf(b, sizeof(b), "\\u%04x", c);
      *out += b;
    } else {
      *out += c;
    }
  }
  *out += '"';
}

VAProfile EncodeProfile(const ComponentCaps& c) {
  VAProfile want = c.codec == Codec::kAvc ? VAProfileH264Main : VAProfileHEVCMain;
  for (VAProfile p : c.va_profiles) {
    if (p == want) return p;
  }
  return c.va_profiles.empty() ? VAProfileNone : c.va_profiles.front();
}

// draw a noise patch moving over a static noise texture
struct Pictures {
  uint32_t w = 0, h = 0;
  std::vector<std::vector<uint8_t>> frames;
  void Make(uint32_t width, uint32_t height) {
    w = width;
    h = height;
    uint32_t s = 0x9e3779b9u;
    auto rnd = [&s]() {
      s ^= s << 13;
      s ^= s >> 17;
      s ^= s << 5;
      return s;
    };
    std::vector<uint8_t> tile(256 * 256);
    for (auto& v : tile) v = static_cast<uint8_t>(16 + rnd() % 220);
    frames.assign(4, std::vector<uint8_t>(static_cast<size_t>(w) * h * 3 / 2));
    for (uint32_t k = 0; k < frames.size(); k++) {
      uint8_t* y = frames[k].data();
      uint8_t* u = y + static_cast<size_t>(w) * h;
      uint8_t* v = u + static_cast<size_t>(w / 2) * (h / 2);
      for (uint32_t r = 0; r < h; r++) {
        for (uint32_t x = 0; x < w; x++) {
          bool moving = (x / 64 + r / 64) % 2 == 0;
          uint32_t tx = moving ? x + 9 * k : x, ty = moving ? r + 5 * k : r;
          y[static_cast<size_t>(r) * w + x] = tile[(ty & 255) * 256 + (tx & 255)];
        }
      }
      for (uint32_t r = 0; r < h / 2; r++) {
        for (uint32_t x = 0; x < w / 2; x++) {
          uint8_t t = tile[((r + 3 * k) & 255) * 256 + ((x * 3 + 7 * k) & 255)];
          u[static_cast<size_t>(r) * (w / 2) + x] = static_cast<uint8_t>(96 + t / 4);
          v[static_cast<size_t>(r) * (w / 2) + x] = static_cast<uint8_t>(160 - t / 4);
        }
      }
    }
  }
  YuvSrc Src(uint32_t k) const {
    const uint8_t* y = frames[k % frames.size()].data();
    const uint8_t* u = y + static_cast<size_t>(w) * h;
    const uint8_t* v = u + static_cast<size_t>(w / 2) * (h / 2);
    int32_t iw = static_cast<int32_t>(w), ih = static_cast<int32_t>(h);
    return YuvSrc{{y, iw, 1}, {u, iw / 2, 1}, {v, iw / 2, 1}, iw, ih};
  }
};

// draw a window panning over a still picture
struct Scene {
  static constexpr uint32_t kMargin = 256;
  uint32_t w = 0, h = 0, bw = 0, bh = 0;
  std::vector<uint8_t> by, bu, bv;
  std::vector<int8_t> noise;
  std::vector<uint8_t> frame;
  void Make(uint32_t width, uint32_t height) {
    w = width;
    h = height;
    bw = w + kMargin;
    bh = h + kMargin;
    by.assign(static_cast<size_t>(bw) * bh, 0);
    bu.assign(static_cast<size_t>(bw / 2) * (bh / 2), 0);
    bv.assign(bu.size(), 0);
    for (uint32_t r = 0; r < bh; r++) {
      for (uint32_t x = 0; x < bw; x++) {
        uint32_t g = 16 + (x + r) * 180 / (bw + bh);
        uint32_t band = ((x / 96 + r / 64) % 3) * 12;
        bool fine = (x / 160 + r / 120) % 4 == 1;
        uint32_t tex = fine ? ((x ^ r) & 3) * 9 : 0;
        by[static_cast<size_t>(r) * bw + x] = static_cast<uint8_t>(std::min<uint32_t>(235, g + band + tex));
      }
    }
    for (uint32_t r = 0; r < bh / 2; r++) {
      for (uint32_t x = 0; x < bw / 2; x++) {
        bu[static_cast<size_t>(r) * (bw / 2) + x] = static_cast<uint8_t>(96 + x * 64 / (bw / 2));
        bv[static_cast<size_t>(r) * (bw / 2) + x] = static_cast<uint8_t>(176 - r * 64 / (bh / 2));
      }
    }
    noise.assign(256 * 256, 0);
    uint32_t s = 0x2545f491u;
    for (auto& n : noise) {
      s ^= s << 13;
      s ^= s >> 17;
      s ^= s << 5;
      n = static_cast<int8_t>(static_cast<int>(s % 9) - 4);
    }
    frame.assign(static_cast<size_t>(w) * h * 3 / 2, 0);
  }
  YuvSrc Src(uint32_t k) {
    const uint32_t ox = (4 * k) % kMargin, oy = (2 * k) % kMargin, nx = (37 * k) & 255, ny = (91 * k) & 255;
    uint8_t* y = frame.data();
    uint8_t* u = y + static_cast<size_t>(w) * h;
    uint8_t* v = u + static_cast<size_t>(w / 2) * (h / 2);
    for (uint32_t r = 0; r < h; r++) {
      const uint8_t* src = &by[static_cast<size_t>(r + oy) * bw + ox];
      const int8_t* nz = &noise[static_cast<size_t>((r + ny) & 255) * 256];
      uint8_t* dst = y + static_cast<size_t>(r) * w;
      for (uint32_t x = 0; x < w; x++) {
        int val = src[x] + nz[(x + nx) & 255];
        dst[x] = static_cast<uint8_t>(val < 16 ? 16 : val > 235 ? 235 : val);
      }
    }
    for (uint32_t r = 0; r < h / 2; r++) {
      memcpy(u + static_cast<size_t>(r) * (w / 2), &bu[static_cast<size_t>(r + oy / 2) * (bw / 2) + ox / 2], w / 2);
      memcpy(v + static_cast<size_t>(r) * (w / 2), &bv[static_cast<size_t>(r + oy / 2) * (bw / 2) + ox / 2], w / 2);
    }
    int32_t iw = static_cast<int32_t>(w), ih = static_cast<int32_t>(h);
    return YuvSrc{{y, iw, 1}, {u, iw / 2, 1}, {v, iw / 2, 1}, iw, ih};
  }
};

// encode a stream of src's pictures at a bitrate
std::string EncodeStream(const ComponentCaps& c, uint32_t w, uint32_t h, const std::function<YuvSrc(uint32_t)>& src,
                         uint32_t frames, uint32_t bitrate, uint32_t keyframe_interval, const MeasureOptions& o,
                         VaDevice& device, std::vector<uint8_t>* csd, std::vector<std::vector<uint8_t>>* aus,
                         double* ms, uint32_t* submitted, std::vector<double>* out_ms = nullptr) {
  EncoderConfig cfg{};
  cfg.profile = EncodeProfile(c);
  cfg.level = c.codec == Codec::kAvc ? 10 : 30;
  cfg.width = w;
  cfg.height = h;
  cfg.framerate_num = 30;
  cfg.framerate_den = 1;
  cfg.bitrate = bitrate;
  cfg.rate_control = EncoderConfig::RateControl::kCbr;
  cfg.keyframe_interval = keyframe_interval;
  cfg.color.matrix = 1;
  cfg.color.full_range = false;
  bool empty = false;
  EncodeCallbacks cb;
  cb.output = [&](const uint8_t* data, size_t size, uint64_t, int64_t, bool, bool codec_config) {
    if (codec_config) {
      csd->assign(data, data + size);
      return;
    }
    if (size == 0) empty = true;
    aus->emplace_back(data, data + size);
    if (out_ms) out_ms->push_back(NowMs());
  };
  Status st;
  auto s = EncodeSession::Create(c.codec, cfg, cb, &st, device);
  if (!s) return std::string("no encode session (status ") + std::to_string(static_cast<int>(st)) + ")";
  double t0 = NowMs();
  uint32_t n = 0;
  for (; n < frames && NowMs() - t0 < o.step_ms; n++) {
    st = s->Encode(src(n), n, n, n == 0);
    if (st != Status::kOk) {
      return "encode of picture " + std::to_string(n) + " failed (" + std::to_string(static_cast<int>(st)) + ")";
    }
  }
  st = s->Drain();
  *ms = NowMs() - t0;
  *submitted = n;
  if (st != Status::kOk) return "drain failed (" + std::to_string(static_cast<int>(st)) + ")";
  if (empty || aus->size() != n || n == 0) {
    return std::to_string(aus->size()) + " access units for " + std::to_string(n) + " pictures" +
           (empty ? ", some empty" : "");
  }
  return "";
}

// hold a guest-memory YV12 buffer in the allocator's layout
struct GuestBuffer {
  int fd = -1;
  uint8_t* map = nullptr;
  size_t bytes = 0;
  int32_t ys = 0, cs = 0;
  size_t cr = 0, cb = 0;
  GuestBuffer() = default;
  GuestBuffer(const GuestBuffer&) = delete;
  GuestBuffer& operator=(const GuestBuffer&) = delete;
  ~GuestBuffer() {
    if (map) munmap(map, bytes);
    if (fd >= 0) close(fd);
  }
  bool Make(uint32_t w, uint32_t h) {
    ys = static_cast<int32_t>((w + 15) & ~15u);
    cs = (ys / 2 + 15) & ~15;
    cr = static_cast<size_t>(ys) * h;
    cb = cr + static_cast<size_t>(cs) * (h / 2);
    bytes = cb + static_cast<size_t>(cs) * (h / 2);
    fd = memfd_create("rhizo-measure-input", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, static_cast<off_t>(bytes)) != 0) return false;
    void* m = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) return false;
    map = static_cast<uint8_t*>(m);
    return true;
  }
  // write a picture into the buffer
  void Write(const YuvSrc& s, uint32_t w, uint32_t h) {
    for (uint32_t r = 0; r < h; r++) memcpy(map + static_cast<size_t>(r) * ys, s.y.data + r * s.y.row_stride, w);
    for (uint32_t r = 0; r < h / 2; r++) {
      memcpy(map + cr + static_cast<size_t>(r) * cs, s.cr.data + r * s.cr.row_stride, w / 2);
      memcpy(map + cb + static_cast<size_t>(r) * cs, s.cb.data + r * s.cb.row_stride, w / 2);
    }
  }
  // return the mapped view as a YuvSrc
  YuvSrc Src(uint32_t w, uint32_t h) const {
    return YuvSrc{{map, ys, 1}, {map + cb, cs, 1}, {map + cr, cs, 1}, static_cast<int32_t>(w),
                  static_cast<int32_t>(h)};
  }
};

// measure an encoder fed from a ring of guest-memory buffers
std::string Encode(const ComponentCaps& c, uint32_t w, uint32_t h, const Pictures& pics, const MeasureOptions& o,
                   VaDevice& device, Measurement* m, std::vector<uint8_t>* csd,
                   std::vector<std::vector<uint8_t>>* aus) {
  std::vector<std::unique_ptr<GuestBuffer>> ring;
  for (uint32_t i = 0; i < std::max(1u, o.input_ring); i++) {
    ring.push_back(std::make_unique<GuestBuffer>());
    if (!ring.back()->Make(w, h)) return "no guest-memory input buffer";
    ring.back()->Write(pics.Src(i), w, h);
  }
  EncoderConfig cfg{};
  cfg.profile = EncodeProfile(c);
  cfg.level = c.codec == Codec::kAvc ? 10 : 30;
  cfg.width = w;
  cfg.height = h;
  cfg.framerate_num = 30;
  cfg.framerate_den = 1;
  cfg.bitrate = std::max<uint32_t>(64000, static_cast<uint32_t>(0.1 * w * h * 30));
  cfg.rate_control = EncoderConfig::RateControl::kCbr;
  cfg.keyframe_interval = 30;
  cfg.color.matrix = 1;
  cfg.color.full_range = false;
  bool empty = false;
  std::vector<double> out_ms;
  EncodeCallbacks cb;
  cb.output = [&](const uint8_t* data, size_t size, uint64_t, int64_t, bool, bool codec_config) {
    if (codec_config) {
      csd->assign(data, data + size);
      return;
    }
    if (size == 0) empty = true;
    aus->emplace_back(data, data + size);
    out_ms.push_back(NowMs());
  };
  Status st;
  auto s = EncodeSession::Create(c.codec, cfg, cb, &st, device);
  if (!s) return std::string("no encode session (status ") + std::to_string(static_cast<int>(st)) + ")";
  const bool settling = static_cast<uint64_t>(w) * h >= o.settle_min_pixels;
  const double sub_ms = settling ? o.window_ms / 3.0 : o.small_window_ms;
  std::vector<std::pair<uint32_t, double>> subs;
  size_t opened = 0;
  bool settled = false;
  auto median3 = [&](bool* agree) {
    double r[3];
    for (int i = 0; i < 3; i++) {
      const auto& sw = subs[subs.size() - 3 + i];
      r[i] = sw.second > 0 ? sw.first * 1000.0 / sw.second : 0;
    }
    double lo = std::min({r[0], r[1], r[2]}), hi = std::max({r[0], r[1], r[2]}), med = r[0] + r[1] + r[2] - lo - hi;
    if (agree) *agree = med > 0 && hi - med <= o.settle * med && med - lo <= o.settle * med;
    return med;
  };
  double t0 = NowMs();
  uint32_t n = 0;
  for (; !settled && NowMs() - t0 < o.step_ms; n++) {
    st = s->Encode(ring[n % ring.size()]->Src(w, h), n, n, n == 0);
    if (st != Status::kOk) {
      return "encode of picture " + std::to_string(n) + " failed (" + std::to_string(static_cast<int>(st)) + ")";
    }
    size_t got = out_ms.size();
    if (got <= o.encode_warmup_frames) {
      opened = got;
      continue;
    }
    uint32_t pics_in = static_cast<uint32_t>(got - opened);
    double span = out_ms[got - 1] - out_ms[opened - 1];
    if (pics_in % cfg.keyframe_interval == 0 && span >= sub_ms && (settling || pics_in >= o.encode_window_frames)) {
      subs.emplace_back(pics_in, span);
      opened = got;
      bool agree = !settling;
      if (settling && subs.size() >= 3) median3(&agree);
      settled = agree;
    }
  }
  st = s->Drain();
  s.reset();
  if (st != Status::kOk) return "drain failed (" + std::to_string(static_cast<int>(st)) + ")";
  if (empty) return "some access units were empty";
  if (subs.empty()) return std::to_string(out_ms.size()) + " access units in " + std::to_string(o.step_ms) +
                           " ms: too few after the warm-up to measure";
  uint32_t frames = 0;
  double ms = 0;
  for (size_t i = subs.size() >= 3 ? subs.size() - 3 : 0; i < subs.size(); i++) {
    frames += subs[i].first;
    ms += subs[i].second;
  }
  if (o.record_loops) {
    for (size_t i = 1; i < out_ms.size(); i++) m->loop_ms.push_back(out_ms[i] - out_ms[i - 1]);
  }
  m->name = c.name;
  m->width = w;
  m->height = h;
  m->frames = frames;
  m->ms = static_cast<uint32_t>(ms + 0.5);
  m->fps = settling && subs.size() >= 3 ? median3(nullptr) : (ms > 0 ? frames * 1000.0 / ms : 0);
  m->settled = settled;
  m->source = "generated";
  return "";
}

uint32_t StreamKbps(const std::vector<std::vector<uint8_t>>& units) {
  if (units.empty()) return 0;
  uint64_t bytes = 0;
  for (const auto& u : units) bytes += u.size();
  return static_cast<uint32_t>(bytes * 8 * 30 / units.size() / 1000);
}

// write a decoder measurement's stream to dump_dir
void Dump(const MeasureOptions& o, const ComponentCaps& c, uint32_t w, uint32_t h, const std::vector<uint8_t>& csd,
          const std::vector<std::vector<uint8_t>>& units) {
  if (o.dump_dir.empty()) return;
  const bool ivf = c.codec == Codec::kVp9 || c.codec == Codec::kAv1;
  std::string path = o.dump_dir + "/" + CodecName(c.codec) + "-" + SizeName(w, h) +
                     (ivf ? ".ivf" : c.codec == Codec::kAvc ? ".h264" : ".h265");
  FILE* f = fopen(path.c_str(), "wb");
  if (!f) return;
  auto le16 = [f](uint32_t v) {
    uint8_t b[2] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8)};
    fwrite(b, 1, 2, f);
  };
  auto le32 = [&le16](uint32_t v) {
    le16(v & 0xffff);
    le16(v >> 16);
  };
  if (ivf) {
    fwrite("DKIF", 1, 4, f);
    le16(0);
    le16(32);
    fwrite(c.codec == Codec::kVp9 ? "VP90" : "AV01", 1, 4, f);
    le16(w);
    le16(h);
    le32(30);
    le32(1);
    le32(static_cast<uint32_t>(units.size()));
    le32(0);
    for (size_t i = 0; i < units.size(); i++) {
      le32(static_cast<uint32_t>(units[i].size()));
      le32(static_cast<uint32_t>(i));
      le32(0);
      fwrite(units[i].data(), 1, units[i].size(), f);
    }
  } else {
    fwrite(csd.data(), 1, csd.size(), f);
    for (const auto& u : units) fwrite(u.data(), 1, u.size(), f);
  }
  fclose(f);
}

// measure a decoder's rate on a looped stream
std::string Decode(const ComponentCaps& c, uint32_t w, uint32_t h, const std::vector<uint8_t>& csd,
                   const std::vector<std::vector<uint8_t>>& units, const MeasureOptions& o, VaDevice& device,
                   const char* source, Measurement* m, std::map<std::string, double>* steps) {
  if (units.empty()) return "no stream";
  Dump(o, c, w, h, csd, units);
  DecodeSession* session = nullptr;
  VADisplay dpy = nullptr;
  VASurfaceID rgba = VA_INVALID_SURFACE;
  uint32_t out = 0, window_out = 0, sub_pics = 0;
  double t_first = 0, t_window = -1, in_callback = 0, draw_ms = 0, decode_ms = 0, t_loop = 0, t_sub = 0;
  std::vector<double> loop_ms;
  std::vector<std::pair<uint32_t, double>> subs;
  bool settled = false;
  const size_t loop = units.size();
  const bool settling = static_cast<uint64_t>(w) * h >= o.settle_min_pixels;
  const double sub_ms = settling ? o.window_ms / 3.0 : o.small_window_ms;
  auto last3 = [&](bool* agree) {
    double r[3];
    for (int i = 0; i < 3; i++) {
      const auto& s = subs[subs.size() - 3 + i];
      r[i] = s.second > 0 ? s.first * 1000.0 / s.second : 0;
    }
    double lo = std::min({r[0], r[1], r[2]}), hi = std::max({r[0], r[1], r[2]});
    double med = r[0] + r[1] + r[2] - lo - hi;
    if (agree) *agree = med > 0 && (hi - med) <= o.settle * med && (med - lo) <= o.settle * med;
    return med;
  };
  std::string err;
  ColorInfo color;
  color.matrix = 1;
  color.full_range = false;
  DecodeCallbacks cb;
  cb.output = [&](const Frame& f) {
    double c0 = NowMs();
    if (o.draw && rgba == VA_INVALID_SURFACE && err.empty()) {
      VASurfaceAttrib attr;
      memset(&attr, 0, sizeof(attr));
      attr.type = VASurfaceAttribPixelFormat;
      attr.flags = VA_SURFACE_ATTRIB_SETTABLE;
      attr.value.type = VAGenericValueTypeInteger;
      attr.value.value.i = VA_FOURCC_RGBA;
      if (vaCreateSurfaces(dpy, VA_RT_FORMAT_RGB32, f.crop.width, f.crop.height, &rgba, 1, &attr, 1) !=
          VA_STATUS_SUCCESS) {
        rgba = VA_INVALID_SURFACE;
        err = "no RGB surface";
      }
    }
    if (rgba != VA_INVALID_SURFACE &&
        session->ToRgbaSurface(f, rgba, VA_FOURCC_RGBA, f.crop.width, f.crop.height, color) != Status::kOk &&
        err.empty()) {
      err = "RGB conversion failed";
    }
    session->ReleaseFrame(f);
    double c1 = NowMs();
    in_callback += c1 - c0;
    out++;
    if (t_window >= 0 && !settled) {
      window_out++;
      sub_pics++;
      draw_ms += c1 - c0;
      if (window_out % loop == 0) {
        if (o.record_loops) loop_ms.push_back(c1 - t_loop);
        t_loop = c1;
        if (c1 - t_sub >= sub_ms) {
          subs.emplace_back(sub_pics, c1 - t_sub);
          sub_pics = 0;
          t_sub = c1;
          bool agree = !settling;
          if (settling && subs.size() >= 3) last3(&agree);
          settled = agree && window_out >= o.window_frames;
        }
      }
    } else if (t_window < 0 && out >= o.warmup_frames && c1 - t_first >= o.warmup_ms) {
      t_window = t_loop = t_sub = c1;
    }
  };
  cb.skip = [](uint64_t) {};
  Status st;
  double t_create = NowMs();
  auto owned = DecodeSession::Create(c.codec, cb, &st, device);
  if (!owned) return std::string("no decode session (status ") + std::to_string(static_cast<int>(st)) + ")";
  session = owned.get();
  dpy = session->display();
  t_first = NowMs();
  uint64_t tag = 0;
  if (!csd.empty()) {
    st = session->Decode(csd.data(), csd.size(), tag++, true);
    if (st != Status::kOk) err = "parameter sets refused";
  }
  for (uint64_t fed = 0; err.empty(); fed++) {
    double now = NowMs();
    if (now - t_first >= o.step_ms || settled) break;
    const std::vector<uint8_t>& u = units[fed % units.size()];
    double cb0 = in_callback, d0 = NowMs();
    bool counting = t_window >= 0;
    st = session->Decode(u.data(), u.size(), tag++, false);
    if (counting) decode_ms += (NowMs() - d0) - (in_callback - cb0);
    if (st != Status::kOk) {
      err = "input " + std::to_string(fed) + " refused (" + std::to_string(static_cast<int>(st)) + ")";
    }
  }
  double t_stop = NowMs();
  if (err.empty() && session->Drain() != Status::kOk) err = "drain failed";
  if (rgba != VA_INVALID_SURFACE) vaDestroySurfaces(dpy, &rgba, 1);
  owned.reset();
  if (steps) {
    double opened = t_window >= 0 ? t_window : t_stop;
    (*steps)["decode_create"] += t_first - t_create;
    (*steps)["decode_warmup"] += opened - t_first;
    (*steps)["decode_window"] += t_stop - opened;
    (*steps)["decode_end"] += NowMs() - t_stop;
  }
  if (!err.empty()) return err;
  uint32_t pics = 0;
  double ms = 0, fps = 0;
  size_t first = subs.size() >= 3 ? subs.size() - 3 : 0;
  for (size_t i = first; i < subs.size(); i++) {
    pics += subs[i].first;
    ms += subs[i].second;
  }
  if (subs.size() >= 3) {
    fps = last3(nullptr);
  } else if (ms > 0) {
    fps = pics * 1000.0 / ms;
  }
  if (t_window < 0 || subs.empty() || pics < o.min_window_frames) {
    return std::to_string(out) + " pictures in " + std::to_string(o.step_ms) + " ms: too few after the warm-up to " +
           "measure";
  }
  m->name = c.name;
  m->width = w;
  m->height = h;
  m->frames = pics;
  m->ms = static_cast<uint32_t>(ms + 0.5);
  m->fps = fps;
  m->settled = settled;
  m->source = source;
  m->warmup_ms = static_cast<uint32_t>(t_window - t_create + 0.5);
  m->decode_ms = decode_ms;
  m->draw_ms = draw_ms;
  m->stream_kbps = StreamKbps(units);
  m->loop_ms = loop_ms;
  return "";
}

bool Fits(const ComponentCaps& c, uint32_t w, uint32_t h) {
  return w >= c.min_width && h >= c.min_height && w <= c.max_width && h <= c.max_height;
}

}

std::vector<std::pair<uint32_t, uint32_t>> MeasureLadder(const ComponentCaps& caps) {
  std::vector<std::pair<uint32_t, uint32_t>> out;
  if (caps.kind == Kind::kEncoder) {
    for (const auto& s : kEncodeLadder) {
      if (Fits(caps, s[0], s[1])) out.emplace_back(s[0], s[1]);
    }
    return out;
  }
  for (const LadderSize& s : kDecodeLadder) {
    if (s.codec == caps.codec && Fits(caps, s.width, s.height)) out.emplace_back(s.width, s.height);
  }
  return out;
}

uint32_t DecodeKbps(Codec codec, uint32_t width, uint32_t height) {
  const ClipRate* sd = nullptr;
  for (const ClipRate& r : kCtsRates) {
    if (r.codec != codec) continue;
    if (r.width == width && r.height == height) return r.kbps;
    if (r.width == 720) sd = &r;
  }
  if (!sd) return 0;
  return static_cast<uint32_t>(static_cast<uint64_t>(sd->kbps) * width * height / (720 * 480));
}

std::vector<MeasureClip> ReadMeasureClips(const std::string& dir, std::vector<std::string>* skipped) {
  std::vector<MeasureClip> out;
  std::vector<uint8_t> manifest;
  if (dir.empty()) return out;
  if (!ReadFile(dir + "/clips.tsv", &manifest)) {
    skipped->push_back("measurement clips: no " + dir + "/clips.tsv");
    return out;
  }
  std::string text(manifest.begin(), manifest.end());
  size_t pos = 0;
  while (pos < text.size()) {
    size_t end = text.find('\n', pos);
    std::string line = text.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
    pos = end == std::string::npos ? text.size() : end + 1;
    if (line.empty() || line[0] == '#') continue;
    std::vector<std::string> f;
    size_t p = 0;
    while (p <= line.size()) {
      size_t t = line.find('\t', p);
      f.push_back(line.substr(p, t == std::string::npos ? std::string::npos : t - p));
      if (t == std::string::npos) break;
      p = t + 1;
    }
    MeasureClip clip;
    Codec codec;
    if (f.size() != 7 || f[0].find('/') != std::string::npos || !ParseCodec(f[1], &codec) ||
        (codec != Codec::kVp9 && codec != Codec::kAv1)) {
      skipped->push_back("measurement clips: manifest line \"" + line.substr(0, 80) + "\" is not a clip");
      continue;
    }
    clip.file = f[0];
    clip.codec = codec;
    clip.width = static_cast<uint32_t>(strtoul(f[2].c_str(), nullptr, 10));
    clip.height = static_cast<uint32_t>(strtoul(f[3].c_str(), nullptr, 10));
    clip.frames = static_cast<uint32_t>(strtoul(f[4].c_str(), nullptr, 10));
    size_t bytes = strtoull(f[5].c_str(), nullptr, 10);
    std::vector<uint8_t> data;
    std::vector<Unit> frames;
    std::string fourcc;
    uint32_t fw = 0, fh = 0;
    const char* want = codec == Codec::kVp9 ? "VP90" : "AV01";
    if (!ReadFile(dir + "/" + clip.file, &data)) {
      skipped->push_back("measurement clips: " + clip.file + " does not read");
    } else if (data.size() != bytes) {
      skipped->push_back("measurement clips: " + clip.file + " is " + std::to_string(data.size()) + " bytes, its " +
                         "manifest says " + std::to_string(bytes));
    } else if (!ReadIvf(data, &frames, &fourcc, &fw, &fh) || fourcc != want || fw != clip.width ||
               fh != clip.height || frames.size() != clip.frames || frames.empty()) {
      skipped->push_back("measurement clips: " + clip.file + " is not the " + want + " " +
                         SizeName(clip.width, clip.height) + " IVF of " + std::to_string(clip.frames) +
                         " frames its manifest says");
    } else {
      for (auto& u : frames) clip.units.push_back(std::move(u.data));
      out.push_back(std::move(clip));
    }
  }
  return out;
}

MeasureReport MeasureComponents(const std::vector<ComponentCaps>& components, VaDevice& device,
                                const MeasureOptions& o) {
  MeasureReport r;
  r.budget_ms = o.budget_ms;
  double t0 = NowMs();
  auto over = [&]() { return NowMs() - t0 >= o.budget_ms; };
  auto skip = [&](const std::string& name, uint32_t w, uint32_t h, const std::string& why) {
    r.skipped.push_back(name + " " + SizeName(w, h) + ": " + why);
  };
  auto logged = [&](const Measurement& m) {
    char line[256];
    snprintf(line, sizeof(line), "%s %s: %u pictures in %u ms (%.1f fps)", m.name.c_str(),
             SizeName(m.width, m.height).c_str(), m.frames, m.ms, m.fps);
    std::string s = line;
    if (m.source != "generated") {
      snprintf(line, sizeof(line), "; warm-up %u ms, decode %.0f ms, draw %.0f ms, %u kbit/s", m.warmup_ms,
               m.decode_ms, m.draw_ms, m.stream_kbps);
      s += line;
    }
    r.log.push_back(s);
  };
  const ComponentCaps* decoders[4] = {nullptr, nullptr, nullptr, nullptr};
  const ComponentCaps* encoders[4] = {nullptr, nullptr, nullptr, nullptr};
  for (const ComponentCaps& c : components) {
    int i = static_cast<int>(c.codec);
    if (i < 0 || i > 3) continue;
    if (c.kind == Kind::kDecoder && c.functional == "ok") decoders[i] = &c;
    if (c.kind == Kind::kEncoder) encoders[i] = &c;
  }
  for (Codec codec : {Codec::kAvc, Codec::kHevc}) {
    const ComponentCaps* enc = encoders[static_cast<int>(codec)];
    const ComponentCaps* dec = decoders[static_cast<int>(codec)];
    if (!enc) {
      if (dec) r.skipped.push_back(dec->name + ": no encoder of its codec to make a stream");
      continue;
    }
    std::vector<std::pair<uint32_t, uint32_t>> enc_sizes = MeasureLadder(*enc), sizes = enc_sizes;
    if (dec) {
      for (const auto& s : MeasureLadder(*dec)) {
        if (std::find(sizes.begin(), sizes.end(), s) == sizes.end()) sizes.push_back(s);
      }
    }
    std::sort(sizes.begin(), sizes.end(), [](const std::pair<uint32_t, uint32_t>& a,
                                             const std::pair<uint32_t, uint32_t>& b) {
      return static_cast<uint64_t>(a.first) * a.second < static_cast<uint64_t>(b.first) * b.second;
    });
    Pictures pics;
    for (const auto& size : sizes) {
      uint32_t w = size.first, h = size.second;
      if (std::find(enc_sizes.begin(), enc_sizes.end(), size) != enc_sizes.end()) {
        if (over()) {
          r.complete = false;
          skip(enc->name, w, h, "budget");
          continue;
        }
        double tp = NowMs();
        pics.Make(w, h);
        r.steps["pictures"] += NowMs() - tp;
        Measurement em;
        std::vector<uint8_t> csd;
        std::vector<std::vector<uint8_t>> aus;
        double te = NowMs();
        std::string why = Encode(*enc, w, h, pics, o, device, &em, &csd, &aus);
        r.steps["encode"] += NowMs() - te;
        if (!why.empty()) {
          skip(enc->name, w, h, why);
        } else {
          r.results.push_back(em);
          logged(em);
        }
      }
      if (!dec || !OnDecodeLadder(codec, w, h) || !Fits(*dec, w, h)) continue;
      if (!Fits(*enc, w, h)) {
        skip(dec->name, w, h, "its encoder does not make a stream of this size");
        continue;
      }
      if (over()) {
        r.complete = false;
        skip(dec->name, w, h, "budget");
        continue;
      }
      constexpr uint32_t kGop = 16, kGops = 3;
      Scene scene;
      double ts = NowMs();
      scene.Make(w, h);
      r.steps["scene"] += NowMs() - ts;
      std::vector<uint8_t> dcsd;
      std::vector<std::vector<uint8_t>> all;
      double ms = 0;
      uint32_t n = 0;
      double tse = NowMs();
      std::string why = EncodeStream(*enc, w, h, [&scene](uint32_t k) { return scene.Src(k); }, kGops * kGop,
                         DecodeKbps(codec, w, h) * 1000, kGop, o, device, &dcsd, &all, &ms, &n);
      if (why.empty() && all.size() < kGops * kGop) why = "the encode stopped short of its GOPs";
      if (!why.empty()) {
        skip(dec->name, w, h, "its stream did not encode: " + why);
        continue;
      }
      std::vector<std::vector<uint8_t>> daus(all.end() - kGop, all.end());
      Measurement dm;
      r.steps["stream_encode"] += NowMs() - tse;
      why = Decode(*dec, w, h, dcsd, daus, o, device, "rhizo-encoded", &dm, &r.steps);
      if (!why.empty()) {
        skip(dec->name, w, h, why);
        continue;
      }
      r.results.push_back(dm);
      logged(dm);
    }
  }
  double tc = NowMs();
  std::vector<MeasureClip> clips = ReadMeasureClips(o.clip_dir, &r.skipped);
  r.steps["clips"] += NowMs() - tc;
  for (Codec codec : {Codec::kVp9, Codec::kAv1}) {
    const ComponentCaps* dec = decoders[static_cast<int>(codec)];
    if (!dec) continue;
    bool any = false;
    for (const MeasureClip& clip : clips) {
      if (clip.codec != codec) continue;
      any = true;
      if (!OnDecodeLadder(codec, clip.width, clip.height)) {
        skip(dec->name, clip.width, clip.height, "not a size of its decoder's ladder");
        continue;
      }
      if (!Fits(*dec, clip.width, clip.height)) {
        skip(dec->name, clip.width, clip.height, "outside the decoder's sizes");
        continue;
      }
      if (over()) {
        r.complete = false;
        skip(dec->name, clip.width, clip.height, "budget");
        continue;
      }
      Measurement dm;
      std::string why = Decode(*dec, clip.width, clip.height, {}, clip.units, o, device, "clip", &dm, &r.steps);
      if (!why.empty()) {
        skip(dec->name, clip.width, clip.height, why);
        continue;
      }
      r.results.push_back(dm);
      logged(dm);
    }
    if (!any) r.skipped.push_back(dec->name + ": no measurement clip of its codec");
  }
  r.elapsed_ms = static_cast<uint32_t>(NowMs() - t0 + 0.5);
  return r;
}

std::string MeasurementsJson(const MeasureReport& r) {
  std::string j = "{\"budget_ms\":" + std::to_string(r.budget_ms) + ",\"elapsed_ms\":" + std::to_string(r.elapsed_ms) +
                  ",\"complete\":" + (r.complete ? "true" : "false") + ",\"results\":[";
  for (size_t i = 0; i < r.results.size(); i++) {
    const Measurement& m = r.results[i];
    char fps[32];
    snprintf(fps, sizeof(fps), "%.1f", m.fps);
    if (i) j += ",";
    j += "{\"name\":";
    Json(&j, m.name);
    j += ",\"width\":" + std::to_string(m.width) + ",\"height\":" + std::to_string(m.height) + ",\"fps\":" + fps +
         ",\"frames\":" + std::to_string(m.frames) + ",\"ms\":" + std::to_string(m.ms) + ",\"source\":";
    Json(&j, m.source);
    if (m.source != "generated") {
      char extra[160];
      snprintf(extra, sizeof(extra), ",\"warmup_ms\":%u,\"decode_ms\":%.1f,\"draw_ms\":%.1f,\"kbps\":%u", m.warmup_ms,
               m.decode_ms, m.draw_ms, m.stream_kbps);
      j += extra;
    }
    if (!m.settled) j += ",\"settled\":false";
    if (!m.loop_ms.empty()) {
      j += ",\"loop_ms\":[";
      for (size_t k = 0; k < m.loop_ms.size(); k++) {
        char v[24];
        snprintf(v, sizeof(v), "%s%.2f", k ? "," : "", m.loop_ms[k]);
        j += v;
      }
      j += "]";
    }
    j += "}";
  }
  j += "],\"skipped\":[";
  for (size_t i = 0; i < r.skipped.size(); i++) {
    if (i) j += ",";
    Json(&j, r.skipped[i]);
  }
  j += "],\"steps\":{";
  bool first = true;
  for (const auto& kv : r.steps) {
    char v[64];
    snprintf(v, sizeof(v), "%s\"%s\":%.0f", first ? "" : ",", kv.first.c_str(), kv.second);
    j += v;
    first = false;
  }
  j += "}}";
  return j;
}

}

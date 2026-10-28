#include "tools/functional/functional.h"

#include <stdio.h>
#include <time.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

#include "tools/functional/md5.h"
#include "tools/streams.h"
#include "va/log.h"

namespace rhizo::c2va {

namespace {

double NowMs() {
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

const char* StatusName(Status s) {
  switch (s) {
    case Status::kOk: return "ok";
    case Status::kBadStream: return "bad-stream";
    case Status::kUnsupported: return "unsupported";
    case Status::kNoMemory: return "no-memory";
    case Status::kVaError: return "va-error";
  }
  return "status-unknown";
}

// return whether a profile carries 10-bit samples
bool TenBitOnly(VAProfile p) {
  return p == VAProfileHEVCMain10 || p == VAProfileVP9Profile2 || p == VAProfileH264High10;
}

const FunctionalClip* ClipFor(Codec codec, uint32_t depth) {
  for (size_t i = 0; i < kFunctionalClipCount; i++) {
    if (kFunctionalClips[i].codec == codec && kFunctionalClips[i].bit_depth == depth) return &kFunctionalClips[i];
  }
  return nullptr;
}

// decode a clip and compare its frames with the reference MD5s
std::string DecodeAndCompare(const FunctionalClip& clip, VaDevice& device) {
  std::vector<Unit> units;
  if (clip.framing == ClipFraming::kAnnexB) {
    units = SplitAccessUnits(clip.codec, std::vector<uint8_t>(clip.data, clip.data + clip.size), false);
  } else {
    std::string fourcc;
    uint32_t w = 0, h = 0;
    if (!ReadIvf(std::vector<uint8_t>(clip.data, clip.data + clip.size), &units, &fourcc, &w, &h)) {
      return "embedded clip is not IVF";
    }
  }
  if (units.empty()) return "embedded clip has no access units";

  std::vector<std::string> digests;
  std::string first_error;
  DecodeSession* session = nullptr;
  const int32_t w = static_cast<int32_t>(clip.width), h = static_cast<int32_t>(clip.height);
  const int32_t bps = clip.bit_depth == 10 ? 2 : 1, cw = (w + 1) / 2, ch = (h + 1) / 2;
  std::vector<uint8_t> planes(static_cast<size_t>(w * h + 2 * cw * ch) * bps);
  DecodeCallbacks cb;
  cb.output = [&](const Frame& f) {
    if (first_error.empty() && (f.crop.width != clip.width || f.crop.height != clip.height)) {
      first_error = "frame " + std::to_string(digests.size()) + " is " + std::to_string(f.crop.width) + "x" +
                    std::to_string(f.crop.height) + ", want " + std::to_string(clip.width) + "x" +
                    std::to_string(clip.height);
    }
    if (first_error.empty() && f.bit_depth != clip.bit_depth) {
      first_error = "frame " + std::to_string(digests.size()) + " is " + std::to_string(f.bit_depth) + "-bit";
    }
    std::string digest = "-";
    if (first_error.empty()) {
      uint8_t* p = planes.data();
      YuvDest d{{p, w * bps, bps}, {p + w * h * bps, cw * bps, bps}, {p + (w * h + cw * ch) * bps, cw * bps, bps},
                w, h, bps};
      Status st = session->ToYuv(f, d);
      if (st != Status::kOk) {
        first_error = std::string("ToYuv: ") + StatusName(st);
      } else {
        if (bps == 2) {
          for (size_t i = 0; i + 1 < planes.size(); i += 2) {
            uint16_t v = static_cast<uint16_t>((planes[i] | (planes[i + 1] << 8)) >> 6);
            planes[i] = static_cast<uint8_t>(v & 0xff);
            planes[i + 1] = static_cast<uint8_t>(v >> 8);
          }
        }
        Md5 md5;
        md5.Update(planes.data(), planes.size());
        digest = md5.HexDigest();
      }
    }
    digests.push_back(digest);
    session->ReleaseFrame(f);
  };
  cb.skip = [](uint64_t) {};
  Status st = Status::kOk;
  std::unique_ptr<DecodeSession> owned = DecodeSession::Create(clip.codec, std::move(cb), &st, device);
  if (!owned) return std::string("no decode session: ") + StatusName(st);
  session = owned.get();
  for (size_t i = 0; i < units.size(); i++) {
    st = session->Decode(units[i].data.data(), units[i].data.size(), i, units[i].codec_config);
    if (st != Status::kOk) return "input " + std::to_string(i) + ": " + StatusName(st);
  }
  st = session->Drain();
  if (st != Status::kOk) return std::string("drain: ") + StatusName(st);
  owned.reset();
  if (!first_error.empty()) return first_error;
  if (digests.size() != clip.frames) {
    return std::to_string(digests.size()) + " frames out, want " + std::to_string(clip.frames);
  }
  for (uint32_t i = 0; i < clip.frames; i++) {
    if (digests[i] != clip.md5[i]) {
      return "frame " + std::to_string(i) + " differs from the reference (md5 " + digests[i].substr(0, 8) + ", want " +
             std::string(clip.md5[i]).substr(0, 8) + ")";
    }
  }
  return "ok";
}

}

std::string CheckClip(const FunctionalClip& clip, VaDevice& device, uint32_t timeout_ms, bool* timed_out) {
  struct Shared {
    std::mutex mutex;
    std::condition_variable cv;
    bool done = false;
    std::string verdict;
  };
  auto shared = std::make_shared<Shared>();
  *timed_out = false;
  std::thread worker([shared, &clip, &device] {
    std::string v = DecodeAndCompare(clip, device);
    std::lock_guard<std::mutex> lock(shared->mutex);
    shared->verdict = v;
    shared->done = true;
    shared->cv.notify_all();
  });
  std::unique_lock<std::mutex> lock(shared->mutex);
  if (!shared->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return shared->done; })) {
    lock.unlock();
    worker.detach();
    *timed_out = true;
    return "timeout after " + std::to_string(timeout_ms) + " ms";
  }
  std::string v = shared->verdict;
  lock.unlock();
  worker.join();
  return v;
}

FunctionalReport ApplyFunctionalChecks(std::vector<ComponentCaps>* components, std::vector<DroppedComponent>* dropped,
                                       VaDevice& device, const FunctionalOptions& options) {
  FunctionalReport report;
  double t0 = NowMs();
  std::vector<ComponentCaps> kept;
  auto run = [&](const FunctionalClip* clip) -> std::string {
    if (!clip) return "no embedded clip";
    if (report.wedged) return "not checked: an earlier clip timed out";
    double c0 = NowMs();
    bool timed_out = false;
    std::string v = CheckClip(*clip, device, options.clip_timeout_ms, &timed_out);
    if (timed_out) report.wedged = true;
    char line[512];
    snprintf(line, sizeof(line), "%s: %s (%.0f ms)", clip->name, v.c_str(), NowMs() - c0);
    report.log.push_back(line);
    return v;
  };
  for (ComponentCaps& c : *components) {
    if (c.kind != Kind::kDecoder) {
      c.functional = "unchecked";
      kept.push_back(c);
      continue;
    }
    bool has8 = std::find(c.bit_depths.begin(), c.bit_depths.end(), 8u) != c.bit_depths.end();
    bool has10 = std::find(c.bit_depths.begin(), c.bit_depths.end(), 10u) != c.bit_depths.end();
    std::string base = has8 ? run(ClipFor(c.codec, 8)) : "no 8-bit profile to check";
    if (base != "ok") {
      dropped->push_back({c.name, c.va_profiles, c.bit_depths, base});
      continue;
    }
    c.functional = "ok";
    if (has10) {
      std::string ten = run(ClipFor(c.codec, 10));
      if (ten != "ok") {
        DroppedComponent d{c.name, {}, {10}, "10-bit: " + ten};
        std::vector<VAProfile> left;
        for (VAProfile p : c.va_profiles) (TenBitOnly(p) ? d.va_profiles : left).push_back(p);
        c.va_profiles = left;
        c.bit_depths.erase(std::remove(c.bit_depths.begin(), c.bit_depths.end(), 10u), c.bit_depths.end());
        dropped->push_back(d);
      }
    }
    kept.push_back(c);
  }
  components->swap(kept);
  report.total_ms = static_cast<uint32_t>(NowMs() - t0);
  return report;
}

}

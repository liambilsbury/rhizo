#include "va_encoder.h"

#include <stdlib.h>
#include <string.h>

#include "../../common/bit_reader.h"
#include "bit_writer.h"
#include "log.h"

namespace rhizo::c2va::enc {

namespace {

Status FromVa(VAStatus st) {
  if (st == VA_STATUS_SUCCESS) return Status::kOk;
  if (st == VA_STATUS_ERROR_ALLOCATION_FAILED) return Status::kNoMemory;
  if (st == VA_STATUS_ERROR_UNSUPPORTED_PROFILE || st == VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT ||
      st == VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT || st == VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED)
    return Status::kUnsupported;
  return Status::kVaError;
}

uint32_t Gcd(uint32_t a, uint32_t b) {
  while (b) {
    uint32_t t = a % b;
    a = b;
    b = t;
  }
  return a;
}

// pack a frame rate into va.h's 16-bit numerator and denominator
uint32_t PackFrameRate(uint32_t num, uint32_t den) {
  if (num == 0 || den == 0) return 30;
  uint32_t g = Gcd(num, den);
  num /= g;
  den /= g;
  if (den == 1 && num <= 0xffff) return num;
  if (num > 0xffff || den > 0xffff) {
    double fps = static_cast<double>(num) / den;
    den = 1000;
    num = static_cast<uint32_t>(fps * 1000.0 + 0.5);
    if (num > 0xffff) {
      den = 1;
      num = static_cast<uint32_t>(fps + 0.5);
    }
  }
  return (den << 16) | (num & 0xffff);
}

}

VaEncoderBase::VaEncoderBase(EncoderHost* host, const EncoderConfig& config) : host_(host), config_(config) {}

VaEncoderBase::~VaEncoderBase() {
  for (const InFlight& f : inflight_) {
    void* p = nullptr;
    if (vaMapBuffer(dpy_, coded_[f.slot], &p) == VA_STATUS_SUCCESS) vaUnmapBuffer(dpy_, coded_[f.slot]);
  }
  for (VABufferID& b : coded_)
    if (b != VA_INVALID_ID) vaDestroyBuffer(dpy_, b);
  for (VASurfaceID s : recon_)
    if (s != VA_INVALID_SURFACE) host_->ReleaseReconSurface(s);
}

Status VaEncoderBase::Probe() {
  dpy_ = host_->display();
  if (!dpy_) return Status::kVaError;
  const char* vendor = vaQueryVendorString(dpy_);
  if (vendor && strstr(vendor, " for virgl")) {
    driver_.virgl = true;
    driver_.virgl_host_radeonsi = strstr(vendor, "radeonsi") != nullptr;
  }
  VAConfigAttrib a[3] = {{VAConfigAttribRTFormat, 0}, {VAConfigAttribRateControl, 0},
                         {VAConfigAttribEncPackedHeaders, 0}};
  VAStatus st = vaGetConfigAttributes(dpy_, config_.profile, VAEntrypointEncSlice, a, 3);
  if (st != VA_STATUS_SUCCESS) return FromVa(st);
  driver_.rt_formats = a[0].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : a[0].value;
  driver_.rate_controls = a[1].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : a[1].value;
  driver_.packed_headers = a[2].value == VA_ATTRIB_NOT_SUPPORTED ? 0 : a[2].value;
  EncLog("encoder probe: vendor \"%s\" rt 0x%x rc 0x%x packed 0x%x", vendor ? vendor : "?", driver_.rt_formats,
         driver_.rate_controls, driver_.packed_headers);
  return Status::kOk;
}

Status VaEncoderBase::ChooseRateControl() {
  uint32_t want = VA_RC_CBR;
  switch (config_.rate_control) {
    case EncoderConfig::RateControl::kCbr: want = VA_RC_CBR; break;
    case EncoderConfig::RateControl::kVbr: want = VA_RC_VBR; break;
    case EncoderConfig::RateControl::kCq: want = VA_RC_CQP; break;
  }
  if (driver_.rate_controls && !(driver_.rate_controls & want)) return Status::kUnsupported;
  if (want != VA_RC_CQP && config_.bitrate == 0) return Status::kUnsupported;
  va_rc_ = want;
  // virglrenderer 1.3.0 leaves the host's rate control disabled
  frame_rc_ = driver_.virgl && want != VA_RC_CQP;
  return Status::kOk;
}

Status VaEncoderBase::Start(uint32_t rt_format, CodedSize coded, uint32_t align_width, uint32_t align_height,
                            size_t coded_buffer_size) {
  if (driver_.rt_formats && !(driver_.rt_formats & rt_format)) return Status::kUnsupported;
  const uint32_t needed = VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE | VA_ENC_PACKED_HEADER_SLICE;
  packed_used_ = ((driver_.packed_headers & needed) == needed) ? (packed_wanted_ & needed) : 0;
  VAConfigAttrib attribs[3];
  int n = 0;
  attribs[n++] = {VAConfigAttribRTFormat, rt_format};
  attribs[n++] = {VAConfigAttribRateControl, va_rc_};
  if (packed_used_) attribs[n++] = {VAConfigAttribEncPackedHeaders, packed_used_};
  EncoderConfig surfaces = config_;
  surfaces.width = coded.width;
  surfaces.height = coded.height;
  Status s = host_->Configure(surfaces, attribs, n, align_width, align_height, &ctx_);
  if (s != Status::kOk) return s;
  coded_size_ = coded_buffer_size;
  for (VABufferID& b : coded_) {
    VAStatus st = vaCreateBuffer(dpy_, ctx_, VAEncCodedBufferType, static_cast<unsigned int>(coded_buffer_size), 1,
                                 nullptr, &b);
    if (st != VA_STATUS_SUCCESS) {
      b = VA_INVALID_ID;
      return FromVa(st);
    }
  }
  for (VASurfaceID& r : recon_) {
    s = host_->AcquireReconSurface(&r);
    if (s != Status::kOk) {
      r = VA_INVALID_SURFACE;
      return s;
    }
  }
  fps_ = config_.framerate_den ? static_cast<double>(config_.framerate_num) / config_.framerate_den : 30.0;
  if (fps_ <= 0) fps_ = 30.0;
  bitrate_ = config_.bitrate;
  if (max_bitrate_ && bitrate_ > max_bitrate_) bitrate_ = max_bitrate_;
  if (va_rc_ == VA_RC_CQP) {
    qp_ = static_cast<int>(config_.quality > 51 ? 51 : config_.quality);
  } else {
    qp_ = InitialQp(hevc_, config_.width, config_.height, fps_, bitrate_);
  }
  if (frame_rc_) {
    FrameRcParams p;
    p.vbr = va_rc_ == VA_RC_VBR;
    p.fps = fps_;
    p.bitrate = bitrate_;
    p.peak = p.vbr ? PeakFor(bitrate_) : bitrate_;
    p.gop = config_.keyframe_interval;
    p.initial_qp = qp_;
    p.alpha = kVirglRadeonsiAlpha;
    rc_.Reset(p);
    const char* trace = getenv("RHIZO_ENC_RC_TRACE");
    rc_trace_ = trace && trace[0] == '1';
  }
  EncLog("encoder started: %ux%u coded %ux%u rc 0x%x bitrate %u qp %d packed 0x%x%s", config_.width, config_.height,
         coded.width, coded.height, va_rc_, bitrate_, qp_, packed_used_, driver_.virgl ? " (virgl)" : "");
  return Status::kOk;
}

Status VaEncoderBase::AddBuffer(VABufferType type, const void* data, size_t size, std::vector<VABufferID>* bufs) {
  VABufferID id = VA_INVALID_ID;
  VAStatus st = vaCreateBuffer(dpy_, ctx_, type, static_cast<unsigned int>(size), 1, const_cast<void*>(data), &id);
  if (st != VA_STATUS_SUCCESS) return FromVa(st);
  bufs->push_back(id);
  return Status::kOk;
}

Status VaEncoderBase::AddPacked(uint32_t packed_type, const std::vector<uint8_t>& data, size_t bit_length,
                                std::vector<VABufferID>* bufs) {
  VAEncPackedHeaderParameterBuffer p;
  memset(&p, 0, sizeof(p));
  p.type = packed_type;
  p.bit_length = static_cast<uint32_t>(bit_length);
  p.has_emulation_bytes = 1;
  Status s = AddBuffer(VAEncPackedHeaderParameterBufferType, &p, sizeof(p), bufs);
  if (s != Status::kOk) return s;
  return AddBuffer(VAEncPackedHeaderDataBufferType, data.data(), data.size(), bufs);
}

uint32_t VaEncoderBase::PeakFor(uint32_t bitrate) const {
  uint64_t peak = 2ull * bitrate;
  if (max_bitrate_ && peak > max_bitrate_) peak = max_bitrate_;
  if (peak < bitrate) peak = bitrate;
  return static_cast<uint32_t>(peak);
}

Status VaEncoderBase::AddRateControl(const EncPicture& pic, std::vector<VABufferID>* bufs) {
  if (va_rc_ != VA_RC_CQP) {
    std::vector<uint8_t> b(sizeof(VAEncMiscParameterBuffer) + sizeof(VAEncMiscParameterRateControl), 0);
    auto* misc = reinterpret_cast<VAEncMiscParameterBuffer*>(b.data());
    misc->type = VAEncMiscParameterTypeRateControl;
    auto* rc = reinterpret_cast<VAEncMiscParameterRateControl*>(misc->data);
    if (va_rc_ == VA_RC_VBR) {
      const uint64_t peak = PeakFor(bitrate_);
      rc->bits_per_second = static_cast<uint32_t>(peak);
      rc->target_percentage = static_cast<uint32_t>((100ull * bitrate_ + peak - 1) / peak);
    } else {
      rc->bits_per_second = bitrate_;
      rc->target_percentage = 100;
    }
    rc->window_size = 1000;
    rc->initial_qp = static_cast<uint32_t>(pic.qp);
    rc->rc_flags.bits.disable_frame_skip = 1;
    rc->rc_flags.bits.disable_bit_stuffing = 1;
    Status s = AddBuffer(VAEncMiscParameterBufferType, b.data(), b.size(), bufs);
    if (s != Status::kOk) return s;
  }
  std::vector<uint8_t> f(sizeof(VAEncMiscParameterBuffer) + sizeof(VAEncMiscParameterFrameRate), 0);
  auto* misc = reinterpret_cast<VAEncMiscParameterBuffer*>(f.data());
  misc->type = VAEncMiscParameterTypeFrameRate;
  auto* fr = reinterpret_cast<VAEncMiscParameterFrameRate*>(misc->data);
  fr->framerate = PackFrameRate(config_.framerate_num, config_.framerate_den);
  return AddBuffer(VAEncMiscParameterBufferType, f.data(), f.size(), bufs);
}

void VaEncoderBase::DestroyBuffers(std::vector<VABufferID>* bufs) {
  for (VABufferID b : *bufs) vaDestroyBuffer(dpy_, b);
  bufs->clear();
}

Status VaEncoderBase::Encode(VASurfaceID input, uint64_t tag, int64_t pts, bool force_keyframe) {
  if (failed_) return Status::kVaError;
  EncPicture pic;
  pic.idr = submitted_ == 0 || force_keyframe || force_idr_ ||
            (config_.keyframe_interval != 0 && frames_since_idr_ >= config_.keyframe_interval);
  pic.frames_since_idr = pic.idr ? 0 : frames_since_idr_;
  pic.idr_count = idr_count_;
  pic.input = input;
  pic.recon = recon_[next_recon_];
  pic.ref = pic.idr ? VA_INVALID_SURFACE : last_recon_;
  pic.qp = qp_;
  pic.tag = tag;
  pic.pts = pts;

  Status s = SubmitAndRetire(pic);
  if (s == Status::kOk || !retire_empty_) return s;
  EncLog("picture of tag %llu came back empty: encoding it again as an IDR", static_cast<unsigned long long>(tag));
  if (frame_rc_) rc_.Unpick();
  EncPicture again = pic;
  again.idr = true;
  again.frames_since_idr = 0;
  again.idr_count = idr_count_;
  again.recon = recon_[next_recon_];
  again.ref = VA_INVALID_SURFACE;
  again.qp = qp_;
  s = SubmitAndRetire(again);
  if (s == Status::kOk || !retire_empty_) return s;
  if (frame_rc_) rc_.Unpick();
  force_idr_ = true;
  if (++lost_in_row_ >= 2) {
    EncLog("picture of tag %llu came back empty again, the second input in a row: the encoder fails",
           static_cast<unsigned long long>(tag));
    failed_ = true;
    return Status::kVaError;
  }
  EncLog("picture of tag %llu came back empty again: dropped, the next picture is an IDR",
         static_cast<unsigned long long>(tag));
  host_->Output(nullptr, 0, tag, pts, false, false);
  return Status::kOk;
}

Status VaEncoderBase::SubmitAndRetire(EncPicture pic) {
  retire_empty_ = false;
  const VASurfaceID input = pic.input;
  const uint64_t tag = pic.tag;
  while (inflight_.size() >= static_cast<size_t>(kPipelineDepth)) {
    Status s = Retire();
    if (s != Status::kOk) {
      Quiesce();
      return s;
    }
  }
  const int slot = static_cast<int>(submitted_ % kPipelineDepth);
  if (!Valid(pic, slot)) {
    failed_ = true;
    Quiesce();
    return Status::kVaError;
  }
  if (frame_rc_) pic.qp = rc_.Pick(pic.idr, pic.frames_since_idr);

  std::vector<VABufferID> bufs;
  Status s = Status::kOk;
  if (pic.idr) force_idr_ = false;
  if (pic.idr) s = AddSequenceParams(pic, &bufs);
  if (s == Status::kOk && (pic.idr || rc_dirty_)) s = AddRateControl(pic, &bufs);
  if (s == Status::kOk) s = AddPictureParams(pic, coded_[slot], &bufs);
  if (s == Status::kOk && pic.idr && packed_used_) s = AddPackedParameterSets(pic, &bufs);
  if (s == Status::kOk) s = AddSliceParams(pic, &bufs);
  if (s != Status::kOk) {
    DestroyBuffers(&bufs);
    if (frame_rc_) rc_.Unpick();
    return s;
  }

  VAStatus st = vaBeginPicture(dpy_, ctx_, input);
  if (st == VA_STATUS_SUCCESS) {
    st = vaRenderPicture(dpy_, ctx_, bufs.data(), static_cast<int>(bufs.size()));
    VAStatus end = vaEndPicture(dpy_, ctx_);
    if (st == VA_STATUS_SUCCESS) st = end;
  }
  DestroyBuffers(&bufs);
  if (st != VA_STATUS_SUCCESS) {
    EncLog("encode of tag %llu failed: %s", static_cast<unsigned long long>(tag), vaErrorStr(st));
    if (frame_rc_) rc_.Unpick();
    failed_ = true;
    Quiesce();
    return FromVa(st);
  }
  rc_dirty_ = false;
  inflight_.push_back({pic, slot});
  submitted_++;
  if (pic.idr) {
    idr_count_++;
    frames_since_idr_ = 1;
  } else {
    frames_since_idr_++;
  }
  last_recon_ = pic.recon;
  next_recon_ ^= 1;

  while (!inflight_.empty()) {
    s = Retire();
    if (s != Status::kOk) {
      Quiesce();
      return s;
    }
  }
  return Status::kOk;
}

Status VaEncoderBase::Drain() {
  if (failed_) {
    Quiesce();
    return Status::kVaError;
  }
  return RetireAll();
}

void VaEncoderBase::Quiesce() {
  for (const InFlight& f : inflight_) {
    void* p = nullptr;
    if (vaMapBuffer(dpy_, coded_[f.slot], &p) == VA_STATUS_SUCCESS) vaUnmapBuffer(dpy_, coded_[f.slot]);
  }
  inflight_.clear();
}

bool VaEncoderBase::Valid(const EncPicture& pic, int slot) const {
  auto own = [this](VASurfaceID s) { return s != VA_INVALID_SURFACE && (s == recon_[0] || s == recon_[1]); };
  const char* why = nullptr;
  if (pic.input == VA_INVALID_SURFACE) why = "no input surface";
  else if (pic.input == recon_[0] || pic.input == recon_[1]) why = "the input is a reconstructed surface";
  else if (!own(pic.recon)) why = "the reconstruction is not one of the encoder's surfaces";
  else if (!pic.idr && (!own(pic.ref) || pic.ref == pic.recon)) why = "the reference is not the previous reconstruction";
  else if (pic.idr && pic.ref != VA_INVALID_SURFACE) why = "an IDR names a reference";
  else if (slot < 0 || slot >= kPipelineDepth || coded_[slot] == VA_INVALID_ID) why = "no coded buffer";
  if (why) EncLog("picture of tag %llu not submitted: %s", static_cast<unsigned long long>(pic.tag), why);
  return why == nullptr;
}

size_t VaEncoderBase::CodedBufferSize(uint32_t aligned_width, uint32_t aligned_height, bool ten_bit) {
  const size_t samples = static_cast<size_t>(aligned_width) * aligned_height;
  const size_t raw = samples * 3 / 2 * (ten_bit ? 2 : 1);
  const size_t host = samples / 256 * 512;
  const size_t size = (raw > host ? raw : host) + 64 * 1024;
  return (size + 4095) & ~static_cast<size_t>(4095);
}

Status VaEncoderBase::SetBitrate(uint32_t bitrate) {
  if (bitrate == 0) return Status::kUnsupported;
  if (max_bitrate_ && bitrate > max_bitrate_) bitrate = max_bitrate_;
  if (bitrate != bitrate_) {
    bitrate_ = bitrate;
    rc_dirty_ = true;
    if (frame_rc_) rc_.SetBitrate(bitrate_, va_rc_ == VA_RC_VBR ? PeakFor(bitrate_) : bitrate_);
  }
  return Status::kOk;
}

Status VaEncoderBase::RetireAll() {
  while (!inflight_.empty()) {
    Status s = Retire();
    if (s != Status::kOk) return s;
  }
  return Status::kOk;
}

Status VaEncoderBase::Retire() {
  InFlight f = inflight_.front();
  inflight_.pop_front();
  void* p = nullptr;
  VAStatus st = vaMapBuffer(dpy_, coded_[f.slot], &p);
  if (st != VA_STATUS_SUCCESS) {
    EncLog("coded buffer of tag %llu: %s", static_cast<unsigned long long>(f.pic.tag), vaErrorStr(st));
    failed_ = true;
    return FromVa(st);
  }
  std::vector<uint8_t> coded;
  bool bad = false;
  int segments = 0;
  char segs[160] = "";
  size_t used = 0;
  for (auto* seg = static_cast<VACodedBufferSegment*>(p); seg && segments < 1024;
       seg = static_cast<VACodedBufferSegment*>(seg->next), segments++) {
    if (used < sizeof(segs) - 1)
      used += static_cast<size_t>(snprintf(segs + used, sizeof(segs) - used, "%s[size %u off %u status 0x%x buf %s]",
                                           segments ? " " : "", seg->size, seg->bit_offset, seg->status,
                                           seg->buf ? "set" : "null"));
    if (seg->status & VA_CODED_BUF_STATUS_BAD_BITSTREAM) bad = true;
    if (seg->bit_offset % 8) {
      bad = true;
      continue;
    }
    const size_t off = seg->bit_offset / 8;
    if (seg->size > coded_size_ || coded.size() + seg->size > coded_size_) {
      bad = true;
      break;
    }
    if (seg->buf && seg->size > off)
      coded.insert(coded.end(), static_cast<uint8_t*>(seg->buf) + off, static_cast<uint8_t*>(seg->buf) + seg->size);
  }
  vaUnmapBuffer(dpy_, coded_[f.slot]);
  if (bad || coded.empty()) {
    EncLog("coded buffer of tag %llu is %s: %d segments %s", static_cast<unsigned long long>(f.pic.tag),
           bad ? "bad" : "empty", segments, segs);
    if (bad || inflight_.size()) failed_ = true;
    else retire_empty_ = true;
    return Status::kVaError;
  }
  Status s = Emit(f.pic, coded);
  if (s != Status::kOk) failed_ = true;
  else lost_in_row_ = 0;
  return s;
}

Status VaEncoderBase::Emit(const EncPicture& pic, const std::vector<uint8_t>& coded) {
  std::vector<NalSpan> nals = SplitAnnexB(coded.data(), coded.size());
  std::vector<uint8_t> params;
  bool has_slice = false;
  for (const NalSpan& n : nals) {
    NalClass c = Classify(n.data, n.size);
    if (c == NalClass::kParameterSet) AppendRawNal(n.data, n.size, &params);
    if (c == NalClass::kSlice) has_slice = true;
  }
  if (!has_slice) {
    EncLog("coded output of tag %llu holds no slice (%zu bytes)", static_cast<unsigned long long>(pic.tag),
           coded.size());
    return Status::kVaError;
  }
  if (pic.idr && !decided_) {
    decided_ = true;
    driver_param_sets_ = !params.empty();
    EncLog("parameter sets: %s", driver_param_sets_ ? "the driver's" : "the core's (the driver wrote none)");
  }
  if (pic.idr) {
    std::vector<uint8_t> cfg;
    if (driver_param_sets_)
      cfg = params;
    else
      OwnParameterSets(&cfg);
    if (!cfg.empty() && cfg != last_config_) {
      host_->Output(cfg.data(), cfg.size(), pic.tag, pic.pts, false, true);
      last_config_ = cfg;
    }
  }
  std::vector<uint8_t> au;
  std::vector<uint8_t> fixed;
  int used_qp = -1;
  for (const NalSpan& n : nals) {
    NalClass c = Classify(n.data, n.size);
    if (c == NalClass::kParameterSet) continue;
    if (c == NalClass::kSlice && !driver_param_sets_) {
      int qp = -1;
      Status s = FixSlice(pic, n.data, n.size, &fixed, &qp);
      if (used_qp < 0) used_qp = qp;
      if (s != Status::kOk) {
        EncLog("slice of tag %llu could not be checked against the core's parameter sets",
               static_cast<unsigned long long>(pic.tag));
        return s;
      }
      if (fixed.size() != n.size || memcmp(fixed.data(), n.data, n.size) != 0) {
        if (rewritten_++ == 0) EncLog("rewriting slice headers the driver wrote against no parameter set");
      }
      AppendRawNal(fixed.data(), fixed.size(), &au);
      continue;
    }
    AppendRawNal(n.data, n.size, &au);
  }
  host_->Output(au.data(), au.size(), pic.tag, pic.pts, pic.idr, false);
  if (frame_rc_) {
    if (rc_trace_)
      EncLog("rc: tag %llu %s asked QP %d, coded at %d, %zu bytes", static_cast<unsigned long long>(pic.tag),
             pic.idr ? "I" : "P", pic.qp, used_qp, au.size());
    rc_.Done(pic.idr, pic.qp, used_qp, au.size());
    if (!rc_.p_qp_followed() && !rc_lock_logged_) {
      rc_lock_logged_ = true;
      EncLog("P pictures come back at the last I picture's QP: rate control steers at I pictures only");
    }
  }
  return Status::kOk;
}

}

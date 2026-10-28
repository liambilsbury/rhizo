// the component capability query

#include <stdio.h>

#include <algorithm>
#include <map>
#include <mutex>
#include <vector>

#include "va/log.h"
#include "va/runtime.h"

namespace rhizo::c2va {

namespace {

constexpr uint32_t kDecoderInstances = 8;
constexpr uint32_t kEncoderInstances = 4;

struct Candidate {
  const char* name;
  const char* mime;
  Codec codec;
  Kind kind;
  std::vector<VAProfile> profiles;
  uint32_t floor_width;
  uint32_t floor_height;
};

constexpr uint32_t kEncoderDeclaredMin = 16;

const std::vector<Candidate>& Candidates() {
  static const std::vector<Candidate> list = {
      {"c2.rhizo.avc.decoder", "video/avc", Codec::kAvc, Kind::kDecoder,
       {VAProfileH264ConstrainedBaseline, VAProfileH264Main, VAProfileH264High, VAProfileH264High10}, 64, 64},
      {"c2.rhizo.hevc.decoder", "video/hevc", Codec::kHevc, Kind::kDecoder,
       {VAProfileHEVCMain, VAProfileHEVCMain10}, 64, 64},
      {"c2.rhizo.vp9.decoder", "video/x-vnd.on2.vp9", Codec::kVp9, Kind::kDecoder,
       {VAProfileVP9Profile0, VAProfileVP9Profile2}, 16, 16},
      {"c2.rhizo.av1.decoder", "video/av01", Codec::kAv1, Kind::kDecoder, {VAProfileAV1Profile0}, 16, 16},
      {"c2.rhizo.avc.encoder", "video/avc", Codec::kAvc, Kind::kEncoder,
       {VAProfileH264ConstrainedBaseline, VAProfileH264Main, VAProfileH264High}, 128, 128},
      {"c2.rhizo.hevc.encoder", "video/hevc", Codec::kHevc, Kind::kEncoder,
       {VAProfileHEVCMain, VAProfileHEVCMain10}, 384, 128},
  };
  return list;
}

bool TenBitOnly(VAProfile p) {
  return p == VAProfileHEVCMain10 || p == VAProfileVP9Profile2 || p == VAProfileH264High10;
}

struct Limits {
  uint32_t min_w = 0, min_h = 0, max_w = 0, max_h = 0;
};

Limits ConfigLimits(VADisplay dpy, VAConfigID config, VAProfile profile, VAEntrypoint ep) {
  Limits l;
  unsigned int n = 0;
  if (vaQuerySurfaceAttributes(dpy, config, nullptr, &n) == VA_STATUS_SUCCESS && n > 0) {
    std::vector<VASurfaceAttrib> attrs(n);
    if (vaQuerySurfaceAttributes(dpy, config, attrs.data(), &n) == VA_STATUS_SUCCESS) {
      for (unsigned int i = 0; i < n; i++) {
        if (attrs[i].value.type != VAGenericValueTypeInteger) continue;
        uint32_t v = static_cast<uint32_t>(attrs[i].value.value.i);
        switch (attrs[i].type) {
          case VASurfaceAttribMinWidth: l.min_w = v; break;
          case VASurfaceAttribMinHeight: l.min_h = v; break;
          case VASurfaceAttribMaxWidth: l.max_w = v; break;
          case VASurfaceAttribMaxHeight: l.max_h = v; break;
          default: break;
        }
      }
    }
  }
  if (l.max_w == 0 || l.max_h == 0) {
    VAConfigAttrib a[2] = {{VAConfigAttribMaxPictureWidth, 0}, {VAConfigAttribMaxPictureHeight, 0}};
    if (vaGetConfigAttributes(dpy, profile, ep, a, 2) == VA_STATUS_SUCCESS) {
      if (a[0].value != VA_ATTRIB_NOT_SUPPORTED) l.max_w = a[0].value;
      if (a[1].value != VA_ATTRIB_NOT_SUPPORTED) l.max_h = a[1].value;
    }
  }
  return l;
}

void JsonString(std::string* out, const std::string& s) {
  out->push_back('"');
  for (unsigned char c : s) {
    switch (c) {
      case '"': *out += "\\\""; break;
      case '\\': *out += "\\\\"; break;
      case '\n': *out += "\\n"; break;
      case '\r': *out += "\\r"; break;
      case '\t': *out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          *out += buf;
        } else {
          out->push_back(static_cast<char>(c));
        }
    }
  }
  out->push_back('"');
}

}

const char* ProfileName(VAProfile profile) {
  switch (profile) {
    case VAProfileH264ConstrainedBaseline: return "VAProfileH264ConstrainedBaseline";
    case VAProfileH264Main: return "VAProfileH264Main";
    case VAProfileH264High: return "VAProfileH264High";
    case VAProfileH264High10: return "VAProfileH264High10";
    case VAProfileHEVCMain: return "VAProfileHEVCMain";
    case VAProfileHEVCMain10: return "VAProfileHEVCMain10";
    case VAProfileVP9Profile0: return "VAProfileVP9Profile0";
    case VAProfileVP9Profile2: return "VAProfileVP9Profile2";
    case VAProfileAV1Profile0: return "VAProfileAV1Profile0";
    case VAProfileNone: return "VAProfileNone";
    default: return "VAProfileUnknown";
  }
}

std::vector<ComponentCaps> QueryComponents(VADisplay dpy) {
  std::vector<ComponentCaps> out;
  // virglrenderer's encode reference pictures are always 8-bit
  const bool virgl = IsVirgl(dpy);
  int max_profiles = vaMaxNumProfiles(dpy);
  if (max_profiles <= 0) return out;
  std::vector<VAProfile> listed(static_cast<size_t>(max_profiles));
  int num_listed = 0;
  if (vaQueryConfigProfiles(dpy, listed.data(), &num_listed) != VA_STATUS_SUCCESS) return out;
  listed.resize(static_cast<size_t>(num_listed));
  int max_eps = vaMaxNumEntrypoints(dpy);
  std::vector<VAEntrypoint> eps(static_cast<size_t>(std::max(max_eps, 1)));

  for (const Candidate& c : Candidates()) {
    VAEntrypoint want = c.kind == Kind::kDecoder ? VAEntrypointVLD : VAEntrypointEncSlice;
    ComponentCaps caps{};
    caps.name = c.name;
    caps.mime = c.mime;
    caps.codec = c.codec;
    caps.kind = c.kind;
    caps.max_instances = c.kind == Kind::kDecoder ? kDecoderInstances : kEncoderInstances;
    bool eight = false, ten = false, any_min = true, first = true;
    for (VAProfile p : c.profiles) {
      if (std::find(listed.begin(), listed.end(), p) == listed.end()) continue;
      if (virgl && c.kind == Kind::kEncoder && TenBitOnly(p)) {
        Logf("%s: %s left out behind virgl (the host's encode reference pictures are 8-bit)", c.name,
             ProfileName(p));
        continue;
      }
      int num_eps = 0;
      if (vaQueryConfigEntrypoints(dpy, p, eps.data(), &num_eps) != VA_STATUS_SUCCESS) continue;
      if (std::find(eps.begin(), eps.begin() + num_eps, want) == eps.begin() + num_eps) continue;
      VAConfigAttrib rt{VAConfigAttribRTFormat, 0};
      if (vaGetConfigAttributes(dpy, p, want, &rt, 1) != VA_STATUS_SUCCESS ||
          rt.value == VA_ATTRIB_NOT_SUPPORTED) {
        rt.value = 0;
      }
      VAConfigID config = VA_INVALID_ID;
      VAStatus st = vaCreateConfig(dpy, p, want, nullptr, 0, &config);
      if (st != VA_STATUS_SUCCESS) {
        Logf("%s: %s offered but its config does not create: %s", c.name, ProfileName(p), vaErrorStr(st));
        continue;
      }
      Limits l = ConfigLimits(dpy, config, p, want);
      uint32_t rc_bits = 0;
      if (c.kind == Kind::kEncoder) {
        VAConfigAttrib rc{VAConfigAttribRateControl, 0};
        if (vaGetConfigAttributes(dpy, p, want, &rc, 1) == VA_STATUS_SUCCESS && rc.value != VA_ATTRIB_NOT_SUPPORTED) {
          rc_bits = rc.value & (VA_RC_CBR | VA_RC_VBR | VA_RC_CQP);
        }
      }
      vaDestroyConfig(dpy, config);
      if (l.max_w == 0 || l.max_h == 0) {
        Logf("%s: %s reports no maximum size, left out", c.name, ProfileName(p));
        continue;
      }
      caps.va_rate_controls = first ? rc_bits : (caps.va_rate_controls & rc_bits);
      caps.va_profiles.push_back(p);
      if (TenBitOnly(p)) {
        ten = true;
      } else {
        eight = true;
        if (p == VAProfileAV1Profile0 && (rt.value & VA_RT_FORMAT_YUV420_10)) ten = true;
      }
      if (l.min_w == 0 || l.min_h == 0) any_min = false;
      if (first) {
        caps.min_width = l.min_w;
        caps.min_height = l.min_h;
        caps.max_width = l.max_w;
        caps.max_height = l.max_h;
      } else {
        caps.min_width = std::max(caps.min_width, l.min_w);
        caps.min_height = std::max(caps.min_height, l.min_h);
        caps.max_width = std::min(caps.max_width, l.max_w);
        caps.max_height = std::min(caps.max_height, l.max_h);
      }
      first = false;
    }
    if (caps.va_profiles.empty()) continue;
    if (c.kind == Kind::kEncoder && caps.va_rate_controls == 0) {
      Logf("%s: no CBR, VBR or CQP rate control, left out", c.name);
      continue;
    }
    caps.min_from_driver = any_min;
    caps.imports_yuv_dmabuf = c.kind == Kind::kEncoder && EncodeSession::ImportsYuvDmabuf(dpy);
    if (!any_min) {
      caps.min_width = std::max(caps.min_width, c.floor_width);
      caps.min_height = std::max(caps.min_height, c.floor_height);
    }
    if (caps.min_width > caps.max_width || caps.min_height > caps.max_height) {
      Logf("%s: minimum %ux%u above maximum %ux%u, left out", c.name, caps.min_width, caps.min_height,
           caps.max_width, caps.max_height);
      continue;
    }
    const uint32_t square_min =
        c.kind == Kind::kEncoder ? kEncoderDeclaredMin : std::max(caps.min_width, caps.min_height);
    const uint32_t square_max = std::min(caps.max_width, caps.max_height);
    if (square_min > square_max) {
      Logf("%s: no size within %ux%u..%ux%u both ways round, left out", c.name, caps.min_width, caps.min_height,
           caps.max_width, caps.max_height);
      continue;
    }
    if (caps.min_width != square_min || caps.min_height != square_min || caps.max_width != square_max ||
        caps.max_height != square_max) {
      Logf("%s: %ux%u..%ux%u declared as %ux%u..%ux%u%s", c.name, caps.min_width, caps.min_height, caps.max_width,
           caps.max_height, square_min, square_min, square_max, square_max,
           c.kind == Kind::kEncoder ? ", a smaller picture coded padded up to the driver's minimum"
                                    : ", the sizes both orientations hold");
    }
    caps.coded_min_width = c.kind == Kind::kEncoder ? caps.min_width : square_min;
    caps.coded_min_height = c.kind == Kind::kEncoder ? caps.min_height : square_min;
    caps.min_width = caps.min_height = square_min;
    caps.max_width = caps.max_height = square_max;
    if (eight) caps.bit_depths.push_back(8);
    if (ten) caps.bit_depths.push_back(10);
    out.push_back(std::move(caps));
  }
  return out;
}

namespace {

std::mutex g_caps_mutex;
std::map<VADisplay, std::vector<ComponentCaps>> g_caps;

}

bool ComponentLimits(VADisplay display, Codec codec, Kind kind, ComponentCaps* out) {
  std::lock_guard<std::mutex> lock(g_caps_mutex);
  auto it = g_caps.find(display);
  if (it == g_caps.end()) it = g_caps.emplace(display, QueryComponents(display)).first;
  for (const ComponentCaps& c : it->second) {
    if (c.codec == codec && c.kind == kind) {
      *out = c;
      return true;
    }
  }
  return false;
}

void ForgetComponents(VADisplay display) {
  std::lock_guard<std::mutex> lock(g_caps_mutex);
  g_caps.erase(display);
}

bool CodecForProfile(VAProfile p, Codec* codec) {
  switch (p) {
    case VAProfileH264ConstrainedBaseline:
    case VAProfileH264Main:
    case VAProfileH264High:
    case VAProfileH264High10: *codec = Codec::kAvc; return true;
    case VAProfileHEVCMain:
    case VAProfileHEVCMain10: *codec = Codec::kHevc; return true;
    case VAProfileVP9Profile0:
    case VAProfileVP9Profile2: *codec = Codec::kVp9; return true;
    case VAProfileAV1Profile0: *codec = Codec::kAv1; return true;
    default: return false;
  }
}

std::vector<ComponentCaps> QueryComponents(VaDevice& device, Status* status) {
  Status st = Status::kOk;
  std::shared_ptr<Display> d = device.Acquire(&st);
  if (status) *status = st;
  if (!d) return {};
  return QueryComponents(d->va());
}

std::string ComponentsJson(const std::string& driver, int va_major, int va_minor,
                           const std::vector<ComponentCaps>& components,
                           const std::vector<DroppedComponent>& dropped, const std::string& measurements) {
  auto profiles = [](std::string* j, const std::vector<VAProfile>& ps) {
    *j += "[";
    for (size_t k = 0; k < ps.size(); k++) {
      if (k) *j += ",";
      JsonString(j, ProfileName(ps[k]));
    }
    *j += "]";
  };
  auto depths = [](std::string* j, const std::vector<uint32_t>& ds) {
    *j += "[";
    for (size_t k = 0; k < ds.size(); k++) {
      if (k) *j += ",";
      *j += std::to_string(ds[k]);
    }
    *j += "]";
  };
  std::string j = "{\"probe\":1,\"driver\":";
  JsonString(&j, driver);
  j += ",\"va_version\":";
  JsonString(&j, std::to_string(va_major) + "." + std::to_string(va_minor));
  j += ",\"components\":[";
  for (size_t i = 0; i < components.size(); i++) {
    const ComponentCaps& c = components[i];
    if (i) j += ",";
    j += "{\"name\":";
    JsonString(&j, c.name);
    j += ",\"mime\":";
    JsonString(&j, c.mime);
    j += ",\"kind\":";
    JsonString(&j, c.kind == Kind::kDecoder ? "decoder" : "encoder");
    j += ",\"va_profiles\":";
    profiles(&j, c.va_profiles);
    j += ",\"bit_depths\":";
    depths(&j, c.bit_depths);
    j += ",\"min_width\":" + std::to_string(c.min_width);
    j += ",\"min_height\":" + std::to_string(c.min_height);
    j += ",\"max_width\":" + std::to_string(c.max_width);
    j += ",\"max_height\":" + std::to_string(c.max_height);
    j += ",\"max_instances\":" + std::to_string(c.max_instances);
    if (c.kind == Kind::kDecoder) j += ",\"features\":[\"adaptive-playback\",\"dynamic-color-aspects\"]";
    if (c.kind == Kind::kEncoder) {
      j += ",\"rate_controls\":[";
      bool any = false;
      const std::pair<uint32_t, const char*> rcs[] = {{VA_RC_CBR, "cbr"}, {VA_RC_VBR, "vbr"}, {VA_RC_CQP, "cq"}};
      for (const auto& rc : rcs) {
        if (!(c.va_rate_controls & rc.first)) continue;
        if (any) j += ",";
        JsonString(&j, rc.second);
        any = true;
      }
      j += "]";
    }
    j += ",\"functional\":";
    JsonString(&j, c.functional);
    j += "}";
  }
  j += "],\"dropped\":[";
  for (size_t i = 0; i < dropped.size(); i++) {
    const DroppedComponent& d = dropped[i];
    if (i) j += ",";
    j += "{\"name\":";
    JsonString(&j, d.name);
    j += ",\"va_profiles\":";
    profiles(&j, d.va_profiles);
    j += ",\"bit_depths\":";
    depths(&j, d.bit_depths);
    j += ",\"functional\":";
    JsonString(&j, d.why);
    j += "}";
  }
  j += "]";
  if (!measurements.empty()) j += ",\"measurements\":" + measurements;
  j += "}";
  return j;
}

}

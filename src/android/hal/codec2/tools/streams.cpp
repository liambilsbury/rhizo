#include "tools/streams.h"

#include <stdio.h>
#include <string.h>

namespace rhizo::c2va {

namespace {

struct Nal {
  size_t start;
  size_t end;
  size_t prefix;
};

// find the NAL units of an Annex B stream
std::vector<Nal> FindNals(const std::vector<uint8_t>& s) {
  std::vector<Nal> nals;
  size_t n = s.size(), i = 0;
  auto start_code_at = [&](size_t p) { return p + 2 < n && s[p] == 0 && s[p + 1] == 0 && s[p + 2] == 1; };
  while (i < n && !start_code_at(i)) i++;
  while (i < n) {
    size_t prefix = (i > 0 && s[i - 1] == 0) ? i - 1 : i;
    size_t begin = i + 3, j = begin;
    while (j < n && !start_code_at(j)) j++;
    size_t end = j;
    while (end > begin && s[end - 1] == 0) end--;
    if (begin < end) nals.push_back({begin, end, prefix});
    i = j;
  }
  return nals;
}

enum class Role { kAuStart, kParam, kVclFirst, kVclRest, kOther };

// classify a NAL unit's access-unit role
Role RoleOf(Codec codec, const std::vector<uint8_t>& s, const Nal& nal) {
  uint8_t h0 = s[nal.start];
  if (codec == Codec::kAvc) {
    int type = h0 & 0x1f;
    if (type == 9) return Role::kAuStart;
    if (type == 7 || type == 8 || type == 15) return Role::kParam;
    if (type == 6 || (type >= 14 && type <= 18)) return Role::kAuStart;
    if (type == 1 || type == 5 || type == 20) {
      size_t p = nal.start + (type == 20 ? 4 : 1);
      if (p < nal.end && (s[p] & 0x80)) return Role::kVclFirst;
      return Role::kVclRest;
    }
    return Role::kOther;
  }
  int type = (h0 >> 1) & 0x3f;
  if (type == 35) return Role::kAuStart;
  if (type >= 32 && type <= 34) return Role::kParam;
  if (type == 39 || (type >= 41 && type <= 44) || (type >= 48 && type <= 55)) return Role::kAuStart;
  if (type <= 31) {
    size_t p = nal.start + 2;
    if (p < nal.end && (s[p] & 0x80)) return Role::kVclFirst;
    return Role::kVclRest;
  }
  return Role::kOther;
}

}

bool ReadFile(const std::string& path, std::vector<uint8_t>* out) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return false;
  out->clear();
  uint8_t buf[1 << 16];
  size_t got;
  while ((got = fread(buf, 1, sizeof(buf), f)) > 0) out->insert(out->end(), buf, buf + got);
  bool ok = !ferror(f);
  fclose(f);
  return ok;
}

std::vector<Unit> SplitAccessUnits(Codec codec, const std::vector<uint8_t>& s, bool csd) {
  std::vector<Unit> units;
  std::vector<Nal> nals = FindNals(s);
  size_t au_begin = 0;
  bool seen_vcl = false;
  auto emit = [&](size_t from, size_t to) {
    if (from >= to) return;
    Unit u;
    u.data.assign(s.begin() + static_cast<long>(nals[from].prefix), s.begin() + static_cast<long>(nals[to - 1].end));
    u.pts = static_cast<int64_t>(units.size());
    units.push_back(std::move(u));
  };
  for (size_t i = 0; i < nals.size(); i++) {
    Role r = RoleOf(codec, s, nals[i]);
    bool starts = r == Role::kAuStart || r == Role::kParam || r == Role::kVclFirst;
    if (seen_vcl && starts) {
      emit(au_begin, i);
      au_begin = i;
      seen_vcl = false;
    }
    if (r == Role::kVclFirst || r == Role::kVclRest) seen_vcl = true;
  }
  emit(au_begin, nals.size());
  if (!csd || units.empty()) return units;

  Unit config, first;
  config.codec_config = true;
  std::vector<Nal> first_nals = FindNals(units[0].data);
  for (const Nal& n : first_nals) {
    Role r = RoleOf(codec, units[0].data, n);
    static const uint8_t sc[4] = {0, 0, 0, 1};
    Unit& dst = r == Role::kParam ? config : first;
    dst.data.insert(dst.data.end(), sc, sc + 4);
    dst.data.insert(dst.data.end(), units[0].data.begin() + static_cast<long>(n.start),
                    units[0].data.begin() + static_cast<long>(n.end));
  }
  if (config.data.empty()) return units;
  first.pts = 0;
  config.pts = 0;
  units[0] = std::move(first);
  units.insert(units.begin(), std::move(config));
  return units;
}

bool ReadIvf(const std::vector<uint8_t>& f, std::vector<Unit>* frames, std::string* fourcc, uint32_t* width,
             uint32_t* height) {
  auto le16 = [&](size_t p) { return static_cast<uint32_t>(f[p] | (f[p + 1] << 8)); };
  auto le32 = [&](size_t p) { return le16(p) | (le16(p + 2) << 16); };
  if (f.size() < 32 || memcmp(f.data(), "DKIF", 4) != 0) return false;
  uint32_t header = le16(6);
  if (header < 32 || header > f.size()) return false;
  fourcc->assign(reinterpret_cast<const char*>(&f[8]), 4);
  *width = le16(12);
  *height = le16(14);
  frames->clear();
  size_t p = header;
  while (p + 12 <= f.size()) {
    uint32_t size = le32(p);
    int64_t pts = static_cast<int64_t>(le32(p + 4)) | (static_cast<int64_t>(le32(p + 8)) << 32);
    p += 12;
    if (size > f.size() - p) return false;
    Unit u;
    u.data.assign(f.begin() + static_cast<long>(p), f.begin() + static_cast<long>(p + size));
    u.pts = pts;
    frames->push_back(std::move(u));
    p += size;
  }
  return true;
}

bool ParseCodec(const std::string& n, Codec* codec) {
  if (n == "avc" || n == "h264") *codec = Codec::kAvc;
  else if (n == "hevc" || n == "h265") *codec = Codec::kHevc;
  else if (n == "vp9") *codec = Codec::kVp9;
  else if (n == "av1") *codec = Codec::kAv1;
  else return false;
  return true;
}

}

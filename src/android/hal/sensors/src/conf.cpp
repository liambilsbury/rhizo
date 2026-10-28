// parse rhizo-sensors.conf
#include "conf.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <cmath>
#include <set>
#include <utility>

namespace rhizo::sensors {

namespace {

constexpr int64_t kRuntimeHandleBase = 0x5F000000;
constexpr size_t kMaxConfBytes = 256 * 1024;

// split a string at runs of spaces and tabs
std::vector<std::string> tokens(const std::string& s) {
  std::vector<std::string> out;
  size_t i = 0;
  while (i < s.size()) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) i++;
    size_t j = i;
    while (j < s.size() && s[j] != ' ' && s[j] != '\t') j++;
    if (j > i) out.push_back(s.substr(i, j - i));
    i = j;
  }
  return out;
}

// strip trailing spaces and tabs
std::string rtrim(const std::string& s) {
  size_t n = s.size();
  while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t')) n--;
  return s.substr(0, n);
}

// parse a finite decimal number
bool parseDouble(const std::string& tok, double* out) {
  if (tok.empty() || tok.find_first_of("xXpP") != std::string::npos) return false;
  for (char c : tok) {
    if (!((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E')) return false;
  }
  errno = 0;
  char* end = nullptr;
  double v = strtod(tok.c_str(), &end);
  if (errno == ERANGE || end != tok.c_str() + tok.size() || !std::isfinite(v)) return false;
  *out = v;
  return true;
}

// parse a decimal int32
bool parseInt(const std::string& tok, int64_t lo, int64_t hi, int32_t* out) {
  if (tok.empty()) return false;
  for (size_t i = 0; i < tok.size(); i++) {
    char c = tok[i];
    if (!((c >= '0' && c <= '9') || (i == 0 && c == '-'))) return false;
  }
  errno = 0;
  char* end = nullptr;
  long long v = strtoll(tok.c_str(), &end, 10);
  if (errno == ERANGE || end != tok.c_str() + tok.size() || v < lo || v > hi) return false;
  *out = static_cast<int32_t>(v);
  return true;
}

// return true for a normalised path strictly under root
bool underRoot(const std::string& path, const std::string& root) {
  if (root.empty() || path.size() <= root.size() || path.compare(0, root.size(), root) != 0) return false;
  if (path.back() == '/') return false;
  std::string rest = "/" + path.substr(root.size()) + "/";
  return rest.find("//") == std::string::npos && rest.find("/./") == std::string::npos &&
         rest.find("/../") == std::string::npos;
}

struct Block {
  SensorConf s;
  std::set<std::string> seen;
  bool hasKind = false;
  bool hasMatrix = false;
  int startLine = 0;
};

class Parser {
 public:
  Parser(const std::string& root, ConfError* err) : root_(root), err_(err) {}

  // record an error and return false
  bool fail(const char* code, int line, const std::string& detail) {
    if (err_) {
      err_->code = code;
      err_->line = line;
      err_->detail = detail;
    }
    return false;
  }

  // parse a sensor directive inside an open block
  bool directive(Block& b, const std::string& word, const std::string& rest, int line) {
    std::vector<std::string> t = tokens(rest);
    SensorConf& s = b.s;
    if (word != "channel") {
      if (b.seen.count(word)) return fail("duplicate", line, "'" + word + "' given twice in one sensor");
      b.seen.insert(word);
    }
    if (word == "kind") {
      if (t.size() != 1) return fail("malformed", line, "kind takes one word");
      if (t[0] == "accelerometer") s.kind = Kind::Accelerometer;
      else if (t[0] == "gyroscope") s.kind = Kind::Gyroscope;
      else if (t[0] == "magnetometer") s.kind = Kind::Magnetometer;
      else if (t[0] == "light") s.kind = Kind::Light;
      else if (t[0] == "proximity") return fail("proximity-not-served", line, "proximity is never served");
      else return fail("bad-value", line, "unknown kind '" + t[0] + "'");
      b.hasKind = true;
      return true;
    }
    if (word == "near") return fail("proximity-not-served", line, "'near' belongs to proximity, never served");
    if (word == "name" || word == "vendor") {
      std::string text = rtrim(rest);
      if (text.empty()) return fail("bad-value", line, word + " is empty");
      (word == "name" ? s.name : s.vendor) = text;
      return true;
    }
    if (word == "device") {
      if (t.size() != 1) return fail("malformed", line, "device takes one path");
      s.device = t[0];
      return true;
    }
    if (word == "channel") {
      if (t.size() < 3 || t.size() > 5) return fail("malformed", line, "channel takes a path, scale, offset and up to two attribute paths");
      ChannelConf c;
      if (!underRoot(t[0], root_)) return fail("bad-path", line, "channel path '" + t[0] + "' is not under " + root_);
      c.path = t[0];
      if (!parseDouble(t[1], &c.scale) || c.scale == 0) return fail("bad-value", line, "scale '" + t[1] + "' is not a finite non-zero number");
      if (!parseDouble(t[2], &c.offset)) return fail("bad-value", line, "offset '" + t[2] + "' is not a finite number");
      for (size_t i = 3; i < t.size(); i++) {
        if (t[i] == "-") continue;
        if (!underRoot(t[i], root_)) return fail("bad-path", line, "attribute path '" + t[i] + "' is not under " + root_);
        (i == 3 ? c.scalePath : c.offsetPath) = t[i];
      }
      if (s.channels.size() >= 3) return fail("channel-count", line, "more than three channels");
      s.channels.push_back(std::move(c));
      return true;
    }
    if (word == "matrix") {
      if (t.size() != 9) return fail("malformed", line, "matrix takes nine numbers");
      for (size_t i = 0; i < 9; i++) {
        if (!parseDouble(t[i], &s.matrix[i])) return fail("bad-value", line, "matrix entry '" + t[i] + "' is not a finite number");
      }
      b.hasMatrix = true;
      return true;
    }
    if (word == "range" || word == "resolution" || word == "power") {
      double v = 0;
      if (t.size() != 1 || !parseDouble(t[0], &v)) return fail("malformed", line, word + " takes one number");
      float f = static_cast<float>(v);
      if (!std::isfinite(f)) return fail("bad-value", line, word + " does not fit a float");
      if (word == "power" ? f < 0 : f <= 0) return fail("bad-value", line, word + " '" + t[0] + "' is out of range");
      (word == "range" ? s.range : word == "resolution" ? s.resolution : s.power) = f;
      return true;
    }
    if (word == "min_delay_us" || word == "max_delay_us") {
      int32_t v = 0;
      if (t.size() != 1 || !parseInt(t[0], 0, INT32_MAX, &v)) return fail("malformed", line, word + " takes one non-negative integer");
      (word == "min_delay_us" ? s.minDelayUs : s.maxDelayUs) = v;
      return true;
    }
    if (word == "mode") {
      if (t.size() != 1) return fail("malformed", line, "mode takes one word");
      if (t[0] == "continuous") s.mode = Mode::Continuous;
      else if (t[0] == "on_change") s.mode = Mode::OnChange;
      else return fail("bad-value", line, "unknown mode '" + t[0] + "'");
      return true;
    }
    b.seen.erase(word);
    return fail("unknown-directive", line, "unknown directive '" + word + "'");
  }

  // check a block at its end line
  bool finish(Block& b, int line) {
    static const char* const kRequired[] = {"kind", "name", "vendor", "device", "range", "resolution",
                                            "power", "min_delay_us", "max_delay_us", "mode"};
    for (const char* f : kRequired) {
      if (!b.seen.count(f)) return fail("missing-field", line, std::string("sensor ") + std::to_string(b.s.handle) + " has no '" + f + "'");
    }
    SensorConf& s = b.s;
    size_t want = isVector(s.kind) ? 3 : 1;
    if (s.channels.size() != want) {
      return fail("channel-count", line, std::string(kindName(s.kind)) + " takes " + std::to_string(want) + " channel lines, got " + std::to_string(s.channels.size()));
    }
    if (isVector(s.kind) && !b.hasMatrix) return fail("matrix", line, std::string(kindName(s.kind)) + " has no matrix");
    if (!isVector(s.kind) && b.hasMatrix) return fail("matrix", line, "a matrix on a scalar kind");
    Mode want_mode = s.kind == Kind::Light ? Mode::OnChange : Mode::Continuous;
    if (s.mode != want_mode) return fail("mode", line, std::string(kindName(s.kind)) + " must be " + (want_mode == Mode::OnChange ? "on_change" : "continuous"));
    if (s.mode == Mode::Continuous && s.minDelayUs <= 0) return fail("delays", line, "a continuous sensor needs min_delay_us > 0");
    if (s.maxDelayUs <= 0 || s.maxDelayUs < s.minDelayUs) return fail("delays", line, "max_delay_us must be positive and at least min_delay_us");
    auto key = std::make_pair(static_cast<int>(s.kind), s.name);
    if (names_.count(key)) return fail("duplicate-name", line, "two " + std::string(kindName(s.kind)) + " sensors named '" + s.name + "'");
    names_.insert(key);
    return true;
  }

  // parse a whole conf
  bool run(const std::string& text, Conf* out) {
    if (text.find('\0') != std::string::npos) return fail("malformed", 0, "the file holds a NUL byte");
    bool header = false;
    bool inBlock = false;
    Block b;
    std::set<int32_t> handles;
    int line = 0;
    size_t pos = 0;
    while (pos < text.size()) {
      size_t nl = text.find('\n', pos);
      std::string raw = text.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
      pos = nl == std::string::npos ? text.size() : nl + 1;
      line++;
      for (unsigned char c : raw) {
        if ((c < 0x20 && c != '\t') || c == 0x7f) return fail("malformed", line, "a control character in the line");
      }
      size_t first = raw.find_first_not_of(" \t");
      if (first == std::string::npos || raw[first] == '#') continue;
      std::string body = raw.substr(first);
      size_t sp = body.find_first_of(" \t");
      std::string word = body.substr(0, sp);
      std::string rest;
      if (sp != std::string::npos) {
        size_t r = body.find_first_not_of(" \t", sp);
        if (r != std::string::npos) rest = body.substr(r);
      }
      if (!header) {
        if (word != "rhizo-sensors") return fail("header", line, "the first directive is not 'rhizo-sensors 1'");
        std::vector<std::string> t = tokens(rest);
        if (t.size() != 1 || t[0] != "1") return fail("version", line, "contract version '" + rtrim(rest) + "', this HAL reads 1");
        header = true;
        continue;
      }
      if (word == "rhizo-sensors") return fail("header", line, "a second header");
      if (word == "sensor") {
        if (inBlock) return fail("unterminated-block", line, "sensor " + std::to_string(b.s.handle) + " has no 'end'");
        std::vector<std::string> t = tokens(rest);
        int32_t h = 0;
        if (t.size() != 1 || !parseInt(t[0], 1, kRuntimeHandleBase - 1, &h)) {
          return fail("handle", line, "handle '" + rtrim(rest) + "' is not an integer in 1.." + std::to_string(kRuntimeHandleBase - 1));
        }
        if (handles.count(h)) return fail("handle", line, "handle " + t[0] + " given twice");
        handles.insert(h);
        b = Block();
        b.s.handle = h;
        b.startLine = line;
        inBlock = true;
        continue;
      }
      if (word == "end") {
        if (!inBlock) return fail("outside-block", line, "'end' with no open sensor");
        if (!tokens(rest).empty()) return fail("malformed", line, "'end' takes nothing");
        if (!finish(b, line)) return false;
        out->sensors.push_back(std::move(b.s));
        inBlock = false;
        continue;
      }
      if (!inBlock) return fail("outside-block", line, "'" + word + "' outside a sensor block");
      if (!directive(b, word, rest, line)) return false;
    }
    if (!header) return fail("header", 0, "no 'rhizo-sensors 1' header");
    if (inBlock) return fail("unterminated-block", b.startLine, "sensor " + std::to_string(b.s.handle) + " has no 'end'");
    if (out->sensors.empty()) return fail("no-sensors", 0, "the conf declares no sensor");
    if (out->sensors.size() > kMaxSensors) return fail("too-many", 0, std::to_string(out->sensors.size()) + " sensors, at most " + std::to_string(kMaxSensors));
    int64_t top = *handles.rbegin();
    if (top + static_cast<int64_t>(out->sensors.size()) >= kRuntimeHandleBase) return fail("handle", 0, "derived handles would reach the runtime range");
    return true;
  }

 private:
  std::string root_;
  ConfError* err_;
  std::set<std::pair<int, std::string>> names_;
};

}

// return the conf word for a kind
const char* kindName(Kind kind) {
  switch (kind) {
    case Kind::Accelerometer: return "accelerometer";
    case Kind::Gyroscope: return "gyroscope";
    case Kind::Magnetometer: return "magnetometer";
    case Kind::Light: return "light";
  }
  return "?";
}

// return true for a three-axis kind
bool isVector(Kind kind) {
  return kind != Kind::Light;
}

// return the factor from IIO units to Android units
double unitFactor(Kind kind) {
  return kind == Kind::Magnetometer ? 100.0 : 1.0;
}

// parse a conf's text
bool parseConf(const std::string& text, Conf* out, ConfError* err, const std::string& channelRoot) {
  Conf parsed;
  Parser p(channelRoot, err);
  if (!p.run(text, &parsed)) return false;
  *out = std::move(parsed);
  return true;
}

// read and parse a conf file
bool loadConf(const std::string& path, Conf* out, ConfError* err, const std::string& channelRoot) {
  int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    if (err) *err = {"unreadable", 0, path + ": " + strerror(errno)};
    return false;
  }
  std::string text;
  char buf[4096];
  for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      int e = errno;
      close(fd);
      if (err) *err = {"unreadable", 0, path + ": " + strerror(e)};
      return false;
    }
    if (n == 0) break;
    text.append(buf, static_cast<size_t>(n));
    if (text.size() > kMaxConfBytes) {
      close(fd);
      if (err) *err = {"too-large", 0, path + " is larger than " + std::to_string(kMaxConfBytes) + " bytes"};
      return false;
    }
  }
  close(fd);
  return parseConf(text, out, err, channelRoot);
}

namespace {

// build the served entry of a conf sensor
ServedSensor served(const SensorConf& s, size_t index, bool uncalibrated, int32_t handle) {
  ServedSensor out;
  out.confIndex = index;
  out.uncalibrated = uncalibrated;
  out.handle = handle;
  out.name = uncalibrated ? s.name + " uncalibrated" : s.name;
  out.vendor = s.vendor;
  switch (s.kind) {
    case Kind::Accelerometer: out.type = kTypeAccelerometer; break;
    case Kind::Gyroscope: out.type = kTypeGyroscope; break;
    case Kind::Magnetometer: out.type = uncalibrated ? kTypeMagneticFieldUncalibrated : kTypeMagneticField; break;
    case Kind::Light: out.type = kTypeLight; break;
  }
  out.maxRange = s.range;
  out.resolution = s.resolution;
  out.power = s.power;
  out.minDelayUs = s.minDelayUs;
  out.maxDelayUs = s.maxDelayUs;
  out.flags = s.mode == Mode::OnChange ? kFlagOnChange : kFlagContinuous;
  return out;
}

}

// return the conf sensors, then an uncalibrated twin per magnetometer
std::vector<ServedSensor> servedSensors(const Conf& conf) {
  std::vector<ServedSensor> out;
  int32_t top = 0;
  for (size_t i = 0; i < conf.sensors.size(); i++) {
    out.push_back(served(conf.sensors[i], i, false, conf.sensors[i].handle));
    if (conf.sensors[i].handle > top) top = conf.sensors[i].handle;
  }
  for (size_t i = 0; i < conf.sensors.size(); i++) {
    if (conf.sensors[i].kind != Kind::Magnetometer) continue;
    out.push_back(served(conf.sensors[i], i, true, ++top));
  }
  return out;
}

}

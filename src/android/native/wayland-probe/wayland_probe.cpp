#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <string>
#include <vector>
#include <map>

namespace {

// Wayland socket and receive buffer
struct WlConn {
  int fd = -1;
  std::vector<uint8_t> rbuf;
};

// send a wayland message on the connection
bool SendMsg(WlConn& c, uint32_t objId, uint16_t opcode, const std::vector<uint8_t>& args) {
  uint32_t size = 8 + static_cast<uint32_t>(args.size());
  std::vector<uint8_t> buf(size);
  memcpy(&buf[0], &objId, 4);
  uint32_t word1 = (static_cast<uint32_t>(size) << 16) | opcode;
  memcpy(&buf[4], &word1, 4);
  if (!args.empty()) memcpy(&buf[8], args.data(), args.size());
  ssize_t n = send(c.fd, buf.data(), buf.size(), 0);
  return n == static_cast<ssize_t>(buf.size());
}

// append a 32-bit value to the buffer
void PutU32(std::vector<uint8_t>& v, uint32_t x) {
  size_t o = v.size(); v.resize(o + 4); memcpy(&v[o], &x, 4);
}
// append a padded string to the buffer
void PutString(std::vector<uint8_t>& v, const std::string& s) {
  uint32_t len = static_cast<uint32_t>(s.size()) + 1;
  PutU32(v, len);
  size_t o = v.size();
  v.resize(o + len);
  memcpy(&v[o], s.data(), s.size());
  v[o + s.size()] = 0;
  size_t pad = (4 - (len % 4)) % 4;
  v.resize(v.size() + pad, 0);
}

// fill rbuf to the requested size
bool FillAtLeast(WlConn& c, size_t need) {
  while (c.rbuf.size() < need) {
    uint8_t tmp[4096];
    ssize_t n = recv(c.fd, tmp, sizeof(tmp), 0);
    if (n <= 0) return false;
    c.rbuf.insert(c.rbuf.end(), tmp, tmp + n);
  }
  return true;
}

// Wayland message header and body
struct WlMsg {
  uint32_t objId;
  uint16_t opcode;
  std::vector<uint8_t> body;
};

// read a wayland message from the connection
bool ReadMsg(WlConn& c, WlMsg* out) {
  if (!FillAtLeast(c, 8)) return false;
  uint32_t objId, word1;
  memcpy(&objId, &c.rbuf[0], 4);
  memcpy(&word1, &c.rbuf[4], 4);
  uint16_t opcode = word1 & 0xffff;
  uint16_t size = (word1 >> 16) & 0xffff;
  if (size < 8) return false;
  if (!FillAtLeast(c, size)) return false;
  out->objId = objId;
  out->opcode = opcode;
  out->body.assign(c.rbuf.begin() + 8, c.rbuf.begin() + size);
  c.rbuf.erase(c.rbuf.begin(), c.rbuf.begin() + size);
  return true;
}

// read a 32-bit value and advance the offset
uint32_t ReadU32(const std::vector<uint8_t>& b, size_t& off) {
  uint32_t v; memcpy(&v, &b[off], 4); off += 4; return v;
}
// read a padded wayland string and advance the offset
std::string ReadString(const std::vector<uint8_t>& b, size_t& off) {
  uint32_t len = ReadU32(b, off);
  std::string s(reinterpret_cast<const char*>(&b[off]), len > 0 ? len - 1 : 0);
  size_t pad = (4 - (len % 4)) % 4;
  off += len + pad;
  return s;
}

}

// connect to the Wayland socket and bind globals
int main(int argc, char** argv) {
  const char* xdgRuntimeDir = getenv("XDG_RUNTIME_DIR");
  const char* waylandDisplay = getenv("WAYLAND_DISPLAY");
  if (!xdgRuntimeDir || !waylandDisplay) {
    fprintf(stderr, "FAIL: XDG_RUNTIME_DIR and WAYLAND_DISPLAY must be set\n");
    return 2;
  }
  std::string path = std::string(xdgRuntimeDir) + "/" + waylandDisplay;

  WlConn c;
  c.fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (c.fd < 0) { fprintf(stderr, "FAIL: socket() errno=%d (%s)\n", errno, strerror(errno)); return 1; }

  struct sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (path.size() >= sizeof(addr.sun_path)) { fprintf(stderr, "FAIL: path too long\n"); return 1; }
  strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

  printf("connecting to %s ...\n", path.c_str());
  if (connect(c.fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) {
    fprintf(stderr, "FAIL: connect() errno=%d (%s)\n", errno, strerror(errno));
    return 1;
  }
  printf("PASS: connect() succeeded -- socket namespace boundary crossed\n");

  uint32_t nextId = 2;
  const uint32_t kRegistryId = nextId++;
  const uint32_t kDisplayId = 1;

  { std::vector<uint8_t> args; PutU32(args, kRegistryId);
    if (!SendMsg(c, kDisplayId, 1, args)) { fprintf(stderr, "FAIL: send get_registry\n"); return 1; } }

  const uint32_t kSync1Id = nextId++;
  { std::vector<uint8_t> args; PutU32(args, kSync1Id);
    if (!SendMsg(c, kDisplayId, 0, args)) { fprintf(stderr, "FAIL: send sync#1\n"); return 1; } }

  struct GlobalInfo { uint32_t name; std::string interface; uint32_t version; };
  std::map<std::string, GlobalInfo> globals;
  bool gotSync1Done = false;
  bool protocolError = false;

  while (!gotSync1Done && !protocolError) {
    WlMsg m;
    if (!ReadMsg(c, &m)) { fprintf(stderr, "FAIL: connection closed while awaiting registry\n"); return 1; }
    if (m.objId == kRegistryId && m.opcode == 0) {
      size_t off = 0;
      GlobalInfo g;
      g.name = ReadU32(m.body, off);
      g.interface = ReadString(m.body, off);
      g.version = ReadU32(m.body, off);
      globals[g.interface] = g;
    } else if (m.objId == kDisplayId && m.opcode == 0) {
      size_t off = 0;
      uint32_t badObj = ReadU32(m.body, off);
      uint32_t code = ReadU32(m.body, off);
      std::string msg = ReadString(m.body, off);
      fprintf(stderr, "FAIL: wl_display.error object=%u code=%u message=%s\n", badObj, code, msg.c_str());
      protocolError = true;
    } else if (m.objId == kSync1Id && m.opcode == 0) {
      gotSync1Done = true;
    }
  }
  if (protocolError) return 1;

  printf("PASS: get_registry + sync round trip complete, %zu globals advertised\n", globals.size());
  for (const auto& [iface, g] : globals) {
    if (iface == "wl_compositor" || iface == "xdg_wm_base" || iface == "zwp_linux_dmabuf_v1")
      printf("  found target global: %s v%u (name=%u)\n", iface.c_str(), g.version, g.name);
  }

  const char* kTargets[] = {"wl_compositor", "xdg_wm_base", "zwp_linux_dmabuf_v1"};
  std::vector<std::string> missing;
  std::vector<std::pair<std::string, uint32_t>> toBind;
  for (const char* iface : kTargets) {
    auto it = globals.find(iface);
    if (it == globals.end()) { missing.push_back(iface); continue; }
    uint32_t newId = nextId++;
    std::vector<uint8_t> args;
    PutU32(args, it->second.name);
    PutString(args, it->second.interface);
    PutU32(args, it->second.version);
    PutU32(args, newId);
    if (!SendMsg(c, kRegistryId, 0, args)) { fprintf(stderr, "FAIL: send bind(%s)\n", iface); return 1; }
    toBind.push_back({iface, newId});
  }

  if (!missing.empty()) {
    printf("NOTE: not advertised by this compositor, skipped: ");
    for (auto& m : missing) printf("%s ", m.c_str());
    printf("\n");
  }
  if (toBind.empty()) {
    fprintf(stderr, "FAIL: none of the target globals were advertised at all\n");
    return 1;
  }

  const uint32_t kSync2Id = nextId++;
  { std::vector<uint8_t> args; PutU32(args, kSync2Id);
    if (!SendMsg(c, kDisplayId, 0, args)) { fprintf(stderr, "FAIL: send sync#2\n"); return 1; } }

  bool gotSync2Done = false;
  while (!gotSync2Done && !protocolError) {
    WlMsg m;
    if (!ReadMsg(c, &m)) { fprintf(stderr, "FAIL: connection closed while confirming binds\n"); return 1; }
    if (m.objId == kDisplayId && m.opcode == 0) {
      size_t off = 0;
      uint32_t badObj = ReadU32(m.body, off);
      uint32_t code = ReadU32(m.body, off);
      std::string msg = ReadString(m.body, off);
      fprintf(stderr, "FAIL: wl_display.error object=%u code=%u message=%s (during bind confirm)\n",
              badObj, code, msg.c_str());
      protocolError = true;
    } else if (m.objId == kSync2Id && m.opcode == 0) {
      gotSync2Done = true;
    }
  }
  if (protocolError) return 1;

  printf("PASS: bound %zu global(s) with zero wl_display.error:\n", toBind.size());
  for (auto& [iface, id] : toBind) printf("  %s -> object id %u\n", iface.c_str(), id);
  printf("RHIZO_WAYLAND_PROBE: PASS\n");
  close(c.fd);
  return 0;
}

#pragma once
#include <linux/ethtool.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>

namespace rhizo_wifi {

// AF_INET datagram socket
class IoctlSocket {
 public:
  IoctlSocket() : fd_(socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)) {}
  ~IoctlSocket() {
    if (fd_ >= 0) close(fd_);
  }
  // run an ioctl and return 0 or a negative errno
  int Run(unsigned long req, ifreq* ifr) {
    if (fd_ < 0) return -EBADF;
    return ioctl(fd_, req, ifr) == 0 ? 0 : -errno;
  }

 private:
  int fd_;
};

// fill an ifreq with an interface name
inline ifreq IfReq(const std::string& name) {
  ifreq ifr{};
  strncpy(ifr.ifr_name, name.c_str(), IFNAMSIZ - 1);
  return ifr;
}

// read an interface's flags
inline int GetFlags(const std::string& name, short* flags) {
  IoctlSocket s;
  ifreq ifr = IfReq(name);
  int rc = s.Run(SIOCGIFFLAGS, &ifr);
  if (rc == 0) *flags = ifr.ifr_flags;
  return rc;
}

// bring an interface up or down
inline int SetUp(const std::string& name, bool up) {
  IoctlSocket s;
  ifreq ifr = IfReq(name);
  int rc = s.Run(SIOCGIFFLAGS, &ifr);
  if (rc != 0) return rc;
  const bool is_up = (ifr.ifr_flags & IFF_UP) != 0;
  if (is_up == up) return 0;
  ifr.ifr_flags = up ? short(ifr.ifr_flags | IFF_UP) : short(ifr.ifr_flags & ~IFF_UP);
  return s.Run(SIOCSIFFLAGS, &ifr);
}

// read an interface's current hardware address
inline int GetHwAddr(const std::string& name, std::array<uint8_t, 6>* mac) {
  IoctlSocket s;
  ifreq ifr = IfReq(name);
  int rc = s.Run(SIOCGIFHWADDR, &ifr);
  if (rc == 0) memcpy(mac->data(), ifr.ifr_hwaddr.sa_data, 6);
  return rc;
}

// set an interface's hardware address
inline int SetHwAddr(const std::string& name, const std::array<uint8_t, 6>& mac) {
  IoctlSocket s;
  ifreq ifr = IfReq(name);
  ifr.ifr_hwaddr.sa_family = ARPHRD_ETHER;
  memcpy(ifr.ifr_hwaddr.sa_data, mac.data(), 6);
  return s.Run(SIOCSIFHWADDR, &ifr);
}

// read an interface's permanent address
inline int GetPermAddr(const std::string& name, std::array<uint8_t, 6>* mac) {
  alignas(ethtool_perm_addr) uint8_t req[sizeof(ethtool_perm_addr) + 32] = {};
  ethtool_perm_addr hdr{};
  hdr.cmd = ETHTOOL_GPERMADDR;
  hdr.size = 32;
  memcpy(req, &hdr, sizeof(hdr));
  IoctlSocket s;
  ifreq ifr = IfReq(name);
  ifr.ifr_data = reinterpret_cast<char*>(req);
  int rc = s.Run(SIOCETHTOOL, &ifr);
  if (rc != 0) return rc;
  memcpy(&hdr, req, sizeof(hdr));
  if (hdr.size != 6) return -EINVAL;
  memcpy(mac->data(), req + sizeof(ethtool_perm_addr), 6);
  return 0;
}

// read an interface's driver description
inline int GetDrvInfo(const std::string& name, ethtool_drvinfo* info) {
  *info = ethtool_drvinfo{};
  info->cmd = ETHTOOL_GDRVINFO;
  IoctlSocket s;
  ifreq ifr = IfReq(name);
  ifr.ifr_data = reinterpret_cast<char*>(info);
  return s.Run(SIOCETHTOOL, &ifr);
}

// return true for a nonzero unicast address
inline bool UsableUnicast(const std::array<uint8_t, 6>& mac) {
  if (mac[0] & 0x01) return false;
  for (uint8_t b : mac) {
    if (b) return true;
  }
  return false;
}

}

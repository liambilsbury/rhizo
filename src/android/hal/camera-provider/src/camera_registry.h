#ifndef RHIZO_CAMERA_CAMERA_REGISTRY_H
#define RHIZO_CAMERA_CAMERA_REGISTRY_H

// map host cameras to camera ids and status changes

#include <map>
#include <string>
#include <vector>

#include "camerad_client.h"

namespace rhizo::camera {

// a camera coming or going
struct RegistryChange {
  bool added = false;
  std::string id;
  std::string deviceName;
  HostCamera host;
  const char* why = "";
};

class CameraRegistry {
 public:
  static std::string DeviceName(const std::string& id);
  static std::string IdOf(const std::string& deviceName);
  static std::vector<std::string> InternalCameraIdList() { return {}; }

  std::vector<RegistryChange> apply(const std::vector<HostCamera>& cameras);
  void reject(const std::string& id);
  std::vector<std::string> presentNames() const;
  bool present(const std::string& id) const { return present_.count(id) != 0; }

 private:
  // order ids numerically
  struct IdLess {
    bool operator()(const std::string& a, const std::string& b) const {
      return a.size() != b.size() ? a.size() < b.size() : a < b;
    }
  };
  std::map<std::string, std::string> idsByKey_;
  std::map<std::string, HostCamera, IdLess> present_;
  int nextId_ = 0;
};

// drop repeated statuses and a NOT_PRESENT before any PRESENT
class StatusDedupe {
 public:
  void reset() { sent_.clear(); }
  bool shouldSend(const std::string& deviceName, bool present);

 private:
  std::map<std::string, bool> sent_;
};

}

#endif

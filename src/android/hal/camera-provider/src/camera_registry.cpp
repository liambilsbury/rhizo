#include "camera_registry.h"

#include <set>

namespace rhizo::camera {

namespace {

constexpr char kDeviceNamePrefix[] = "device@1.1/internal/";

// return whether two mode lists are equal
bool SameModes(const std::vector<HostMode>& a, const std::vector<HostMode>& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); i++) {
    if (a[i].width != b[i].width || a[i].height != b[i].height || a[i].fpsNum != b[i].fpsNum ||
        a[i].fpsDen != b[i].fpsDen) {
      return false;
    }
  }
  return true;
}

}

// return the AIDL device name of an id
std::string CameraRegistry::DeviceName(const std::string& id) { return kDeviceNamePrefix + id; }

// return the id in a device name, or empty
std::string CameraRegistry::IdOf(const std::string& deviceName) {
  std::string prefix = kDeviceNamePrefix;
  if (deviceName.size() <= prefix.size() || deviceName.compare(0, prefix.size(), prefix) != 0) return "";
  return deviceName.substr(prefix.size());
}

// apply a camerad LIST and return removals before additions
std::vector<RegistryChange> CameraRegistry::apply(const std::vector<HostCamera>& cameras) {
  std::vector<RegistryChange> removed, added;
  std::set<std::string> listed;
  for (const HostCamera& cam : cameras) {
    auto known = idsByKey_.find(cam.key);
    std::string id = known != idsByKey_.end() ? known->second : std::to_string(nextId_++);
    idsByKey_[cam.key] = id;
    listed.insert(id);
    auto it = present_.find(id);
    if (it != present_.end() && SameModes(it->second.modes, cam.modes)) continue;
    if (it != present_.end()) {
      removed.push_back(RegistryChange{false, id, DeviceName(id), {}, "modes changed"});
      present_.erase(it);
    }
    present_[id] = cam;
    added.push_back(RegistryChange{true, id, DeviceName(id), cam, "listed"});
  }
  for (auto it = present_.begin(); it != present_.end();) {
    if (listed.count(it->first) == 0) {
      removed.push_back(RegistryChange{false, it->first, DeviceName(it->first), {}, "absent from camerad LIST"});
      it = present_.erase(it);
    } else {
      ++it;
    }
  }
  removed.insert(removed.end(), added.begin(), added.end());
  return removed;
}

// erase id from present_
void CameraRegistry::reject(const std::string& id) { present_.erase(id); }

// return DeviceName(id) for each present_ entry
std::vector<std::string> CameraRegistry::presentNames() const {
  std::vector<std::string> out;
  for (const auto& [id, cam] : present_) out.push_back(DeviceName(id));
  return out;
}

// return whether to call cameraDeviceStatusChange for deviceName
bool StatusDedupe::shouldSend(const std::string& deviceName, bool present) {
  auto it = sent_.find(deviceName);
  if (it != sent_.end() && it->second == present) return false;
  if (it == sent_.end() && !present) return false;
  sent_[deviceName] = present;
  return true;
}

}

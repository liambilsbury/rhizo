// the empty registry of a build without the VA runtime

#include "log.h"
#include "registry.h"

namespace rhizo::c2store {

void ConfigureRuntime(int, char**) {}

std::vector<ComponentEntry> BuildRegistry() {
  klogf("built without the VA runtime, 0 components");
  return {};
}

}

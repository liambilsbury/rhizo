// the empty registry of a build without the VA runtime

#include "log.h"
#include "registry.h"

namespace rhizo::c2store {

void ConfigureRuntime(int, char**) {}

std::vector<ComponentEntry> BuildRegistry() {
  klogf("registry: built without the VA runtime, so no component is offered");
  return {};
}

}

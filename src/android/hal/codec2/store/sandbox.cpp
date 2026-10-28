#include "sandbox.h"

#include <unistd.h>

#include <minijail.h>

#include "log.h"

namespace rhizo::c2store {

namespace {

constexpr char kPolicyPath[] = "/vendor/etc/seccomp_policy/rhizo-codec2-service.policy";

}

bool EnterSandbox() {
  // SetUpMinijail aborts on an unreadable policy
  if (access(kPolicyPath, R_OK) != 0) {
    klogf("sandbox: no readable seccomp policy at %s", kPolicyPath);
    return false;
  }
  android::SetUpMinijail(kPolicyPath, "");
  klogf("sandbox: seccomp policy %s applied", kPolicyPath);
  return true;
}

}

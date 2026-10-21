#include "aidl/android/hardware/gatekeeper/BnGatekeeper.h"
#include "aidl/android/hardware/security/sharedsecret/BnSharedSecret.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <openssl/aes.h>
#include <openssl/cmac.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/mem.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <vector>

using namespace aidl::android::hardware::gatekeeper;
using aidl::android::hardware::security::keymint::HardwareAuthenticatorType;
using aidl::android::hardware::security::keymint::HardwareAuthToken;
using aidl::android::hardware::security::secureclock::Timestamp;
using aidl::android::hardware::security::sharedsecret::BnSharedSecret;
using aidl::android::hardware::security::sharedsecret::SharedSecretParameters;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) {
    dprintf(fd, "<5>rhizo-gatekeeper: %s\n", msg);
    close(fd);
  }
}

// return a service-specific error status
ScopedAStatus gkError(int32_t code) { return ScopedAStatus::fromServiceSpecificError(code); }

constexpr int32_t kErrInvalidArgument = -38;

// return the boot-time clock in milliseconds
int64_t nowMillis() {
  struct timespec ts;
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

constexpr uint64_t kOneMinute = 60000;
constexpr uint64_t kOneHour = 60 * kOneMinute;
constexpr uint64_t kOneDay = 24 * kOneHour;
constexpr uint64_t kOneYear = 365 * kOneDay;
constexpr uint64_t kTimeoutTable[] = {
    0,   0,   0,   0,   0,
    kOneMinute,       5 * kOneMinute,    15 * kOneMinute,
    30 * kOneMinute,   90 * kOneMinute,   4 * kOneHour,
    12 * kOneHour,    36 * kOneHour,     4 * kOneDay,
    13 * kOneDay,     41 * kOneDay,      123 * kOneDay,
    kOneYear,         3 * kOneYear,      9 * kOneYear,
};
constexpr size_t kTimeoutTableLen = sizeof(kTimeoutTable) / sizeof(kTimeoutTable[0]);

// return the retry timeout for a failure count
uint64_t computeRetryTimeout(uint32_t failureCounter) {
  if (failureCounter < kTimeoutTableLen) return kTimeoutTable[failureCounter];
  return kTimeoutTable[kTimeoutTableLen - 1];
}

struct FailureRecord {
  uint32_t failureCounter = 0;
  int64_t lastCheckedMillis = 0;
};

constexpr uint8_t kLocalMacKey[32] = {
    0x52, 0x68, 0x69, 0x7a, 0x6f, 0x2d, 0x47, 0x4b, 0x2d, 0x6c, 0x6f, 0x63,
    0x61, 0x6c, 0x2d, 0x6d, 0x61, 0x63, 0x2d, 0x6e, 0x6f, 0x74, 0x2d, 0x66,
    0x69, 0x6e, 0x61, 0x6c, 0x2d, 0x76, 0x31, 0x00};

// derive key bytes with AES-CMAC KDF
bool ckdf(const uint8_t* key, size_t keyLen, const char* label,
          const std::vector<std::pair<const uint8_t*, size_t>>& contextChunks,
          uint8_t* out, size_t outLen) {
  if (keyLen != 16 && keyLen != 32) return false;
  const EVP_CIPHER* algo = (keyLen == 16) ? EVP_aes_128_cbc() : EVP_aes_256_cbc();
  const uint32_t blocks = static_cast<uint32_t>((outLen + AES_BLOCK_SIZE - 1) / AES_BLOCK_SIZE);
  const uint32_t netOrderL = htonl(static_cast<uint32_t>(outLen * 8));
  const size_t labelLen = strlen(label);

  bssl::UniquePtr<CMAC_CTX> ctx(CMAC_CTX_new());
  if (!ctx) return false;

  size_t written = 0;
  for (uint32_t i = 1; i <= blocks; ++i) {
    if (!CMAC_Init(ctx.get(), key, keyLen, algo, nullptr)) return false;
    uint32_t netOrderI = htonl(i);
    if (!CMAC_Update(ctx.get(), reinterpret_cast<uint8_t*>(&netOrderI), sizeof(netOrderI)))
      return false;
    if (!CMAC_Update(ctx.get(), reinterpret_cast<const uint8_t*>(label), labelLen)) return false;
    uint8_t zero = 0;
    if (!CMAC_Update(ctx.get(), &zero, sizeof(zero))) return false;
    for (auto& chunk : contextChunks) {
      if (chunk.second > 0 && !CMAC_Update(ctx.get(), chunk.first, chunk.second)) return false;
    }
    if (!CMAC_Update(ctx.get(), reinterpret_cast<const uint8_t*>(&netOrderL), sizeof(netOrderL)))
      return false;

    uint8_t block[AES_BLOCK_SIZE];
    size_t blockLen;
    if (!CMAC_Final(ctx.get(), block, &blockLen)) return false;
    size_t toCopy = std::min(static_cast<size_t>(blockLen), outLen - written);
    memcpy(out + written, block, toCopy);
    written += toCopy;
    CMAC_Reset(ctx.get());
  }
  return written == outLen;
}

// state of the shared secret negotiation
struct HmacNegotiationState {
  std::mutex mu;
  bool computed = false;
  uint8_t nonce[32] = {};
  bool haveNonce = false;
  uint8_t hmacKey[32] = {};
};
// return the shared HMAC negotiation state
HmacNegotiationState& hmacState() {
  static HmacNegotiationState* state = new HmacNegotiationState();
  return *state;
}
constexpr uint8_t kFakeKeyAgreementKey[32] = {};
constexpr char kKeyAgreementLabel[] = "KeymasterSharedMac";
constexpr char kKeyCheckLabel[] = "Keymaster HMAC Verification";

// ISharedSecret for Gatekeeper tokens
class RhizoSharedSecret : public BnSharedSecret {
 public:
  // return the shared secret seed and nonce
  ScopedAStatus getSharedSecretParameters(SharedSecretParameters* out) override {
    auto& st = hmacState();
    std::lock_guard<std::mutex> lg(st.mu);
    if (!st.haveNonce) {
      RAND_bytes(st.nonce, sizeof(st.nonce));
      st.haveNonce = true;
    }
    out->seed.clear();
    out->nonce.assign(st.nonce, st.nonce + sizeof(st.nonce));
    return ScopedAStatus::ok();
  }

  // compute the shared HMAC key from parameters
  ScopedAStatus computeSharedSecret(const std::vector<SharedSecretParameters>& params,
                                     std::vector<uint8_t>* sharingCheck) override {
    auto& st = hmacState();
    std::lock_guard<std::mutex> lg(st.mu);
    for (auto& p : params) {
      if (p.nonce.size() != sizeof(st.nonce) || (p.seed.size() != 0 && p.seed.size() != 32)) {
        return gkError(kErrInvalidArgument);
      }
    }
    if (!st.haveNonce) {
      return gkError(kErrInvalidArgument);
    }
    bool foundMine = false;
    for (auto& p : params) {
      if (p.seed.empty() && p.nonce.size() == sizeof(st.nonce) &&
          memcmp(p.nonce.data(), st.nonce, sizeof(st.nonce)) == 0) {
        foundMine = true;
        break;
      }
    }
    if (!foundMine) {
      return gkError(kErrInvalidArgument);
    }
    std::vector<std::pair<const uint8_t*, size_t>> chunks;
    chunks.reserve(params.size() * 2);
    for (auto& p : params) {
      chunks.emplace_back(p.seed.data(), p.seed.size());
      chunks.emplace_back(p.nonce.data(), p.nonce.size());
    }
    if (!ckdf(kFakeKeyAgreementKey, sizeof(kFakeKeyAgreementKey), kKeyAgreementLabel, chunks,
              st.hmacKey, sizeof(st.hmacKey))) {
      return gkError(1);
    }
    st.computed = true;
    uint8_t check[SHA256_DIGEST_LENGTH];
    unsigned checkLen = 0;
    HMAC(EVP_sha256(), st.hmacKey, sizeof(st.hmacKey),
         reinterpret_cast<const uint8_t*>(kKeyCheckLabel), strlen(kKeyCheckLabel), check,
         &checkLen);
    sharingCheck->assign(check, check + checkLen);
    klog("RhizoSharedSecret: computeSharedSecret OK, real hmac_key_ negotiated");
    return ScopedAStatus::ok();
  }
};

constexpr char kHandleMagic[4] = {'R', 'Z', 'G', 'K'};
constexpr size_t kSaltLen = 16;
constexpr size_t kHandleLen = 4 + 8 + 8 + kSaltLen + SHA256_DIGEST_LENGTH;

// append a 64-bit value in little-endian order
void putU64(std::vector<uint8_t>* out, uint64_t v) {
  for (int i = 0; i < 8; i++) out->push_back(static_cast<uint8_t>(v >> (i * 8)));
}
// read a little-endian 64-bit value
uint64_t getU64(const uint8_t* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v |= static_cast<uint64_t>(p[i]) << (i * 8);
  return v;
}
// append a big-endian uint32 to the buffer
void putU32BE(std::vector<uint8_t>* out, uint32_t v) {
  for (int i = 3; i >= 0; i--) out->push_back(static_cast<uint8_t>(v >> (i * 8)));
}
// append a 64-bit value in big-endian order
void putU64BE(std::vector<uint8_t>* out, uint64_t v) {
  for (int i = 7; i >= 0; i--) out->push_back(static_cast<uint8_t>(v >> (i * 8)));
}

// return the HMAC-SHA256 of the data
std::vector<uint8_t> hmacSha256(const uint8_t* key, size_t keyLen, const std::vector<uint8_t>& data) {
  std::vector<uint8_t> out(SHA256_DIGEST_LENGTH);
  unsigned int outLen = 0;
  HMAC(EVP_sha256(), key, static_cast<int>(keyLen), data.data(), data.size(), out.data(), &outLen);
  out.resize(outLen);
  return out;
}

// build a password handle from a salted password digest
std::vector<uint8_t> makePasswordHandle(uint64_t secureUserId, uint64_t authenticatorId,
                                         const std::vector<uint8_t>& password) {
  std::vector<uint8_t> salt(kSaltLen);
  RAND_bytes(salt.data(), static_cast<int>(salt.size()));
  std::vector<uint8_t> saltedPassword = salt;
  saltedPassword.insert(saltedPassword.end(), password.begin(), password.end());
  std::vector<uint8_t> digest = hmacSha256(kLocalMacKey, sizeof(kLocalMacKey), saltedPassword);

  std::vector<uint8_t> handle;
  handle.insert(handle.end(), kHandleMagic, kHandleMagic + 4);
  putU64(&handle, secureUserId);
  putU64(&handle, authenticatorId);
  handle.insert(handle.end(), salt.begin(), salt.end());
  handle.insert(handle.end(), digest.begin(), digest.end());
  return handle;
}

// check a password against a password handle
bool verifyPasswordHandle(const std::vector<uint8_t>& handle, const std::vector<uint8_t>& password,
                           uint64_t* secureUserId, uint64_t* authenticatorId) {
  if (handle.size() != kHandleLen) return false;
  if (memcmp(handle.data(), kHandleMagic, 4) != 0) return false;
  uint64_t uid = getU64(handle.data() + 4);
  uint64_t authId = getU64(handle.data() + 12);
  std::vector<uint8_t> salt(handle.begin() + 20, handle.begin() + 20 + kSaltLen);
  std::vector<uint8_t> storedDigest(handle.begin() + 20 + kSaltLen, handle.end());

  std::vector<uint8_t> saltedPassword = salt;
  saltedPassword.insert(saltedPassword.end(), password.begin(), password.end());
  std::vector<uint8_t> computed = hmacSha256(kLocalMacKey, sizeof(kLocalMacKey), saltedPassword);

  if (computed.size() != storedDigest.size()) return false;
  uint8_t diff = 0;
  for (size_t i = 0; i < computed.size(); i++) diff |= computed[i] ^ storedDigest[i];
  if (diff != 0) return false;
  *secureUserId = uid;
  *authenticatorId = authId;
  return true;
}

// IGatekeeper for software password checks
class RhizoGatekeeper : public BnGatekeeper {
 public:
  // delete all enrolled users
  ScopedAStatus deleteAllUsers() override {
    std::lock_guard<std::mutex> lg(mutex_);
    nextAuthenticatorId_.clear();
    failureRecords_.clear();
    for (const auto& [uid, sid] : uidToSecureUserId_) {
      (void)uid;
      deletedSecureUserIds_.insert(sid);
    }
    uidToSecureUserId_.clear();
    return ScopedAStatus::ok();
  }

  // delete an enrolled user
  ScopedAStatus deleteUser(int32_t uid) override {
    std::lock_guard<std::mutex> lg(mutex_);
    nextAuthenticatorId_.erase(uid);
    auto it = uidToSecureUserId_.find(uid);
    if (it == uidToSecureUserId_.end()) {
      return gkError(IGatekeeper::ERROR_GENERAL_FAILURE);
    }
    deletedSecureUserIds_.insert(it->second);
    uidToSecureUserId_.erase(it);
    return ScopedAStatus::ok();
  }

  // enroll a password for a user
  ScopedAStatus enroll(int32_t uid, const std::vector<uint8_t>& currentPasswordHandle,
                       const std::vector<uint8_t>& currentPassword,
                       const std::vector<uint8_t>& desiredPassword,
                       GatekeeperEnrollResponse* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (desiredPassword.empty()) {
      return gkError(IGatekeeper::ERROR_GENERAL_FAILURE);
    }
    uint64_t secureUserId, authenticatorId;
    if (!currentPasswordHandle.empty()) {
      if (!verifyPasswordHandle(currentPasswordHandle, currentPassword, &secureUserId,
                                 &authenticatorId)) {
        return gkError(IGatekeeper::ERROR_GENERAL_FAILURE);
      }
    } else {
      uint8_t idBytes[8];
      RAND_bytes(idBytes, sizeof(idBytes));
      secureUserId = getU64(idBytes);
    }
    uint8_t authIdBytes[8];
    RAND_bytes(authIdBytes, sizeof(authIdBytes));
    authenticatorId = getU64(authIdBytes);

    uidToSecureUserId_[uid] = secureUserId;
    deletedSecureUserIds_.erase(secureUserId);

    out->statusCode = IGatekeeper::STATUS_OK;
    out->timeoutMs = 0;
    out->secureUserId = static_cast<int64_t>(secureUserId);
    out->data = makePasswordHandle(secureUserId, authenticatorId, desiredPassword);
    return ScopedAStatus::ok();
  }

  // verify a password against its handle
  ScopedAStatus verify(int32_t, int64_t challenge, const std::vector<uint8_t>& enrolledPasswordHandle,
                       const std::vector<uint8_t>& providedPassword,
                       GatekeeperVerifyResponse* out) override {
    std::lock_guard<std::mutex> lg(mutex_);
    if (enrolledPasswordHandle.size() != kHandleLen ||
        memcmp(enrolledPasswordHandle.data(), kHandleMagic, 4) != 0) {
      return gkError(IGatekeeper::ERROR_GENERAL_FAILURE);
    }
    uint64_t handleSecureUserId = getU64(enrolledPasswordHandle.data() + 4);

    int64_t now = nowMillis();
    FailureRecord& record = failureRecords_[handleSecureUserId];
    uint64_t pending = computeRetryTimeout(record.failureCounter);
    if (pending > 0 && now < record.lastCheckedMillis + static_cast<int64_t>(pending)) {
      out->statusCode = IGatekeeper::ERROR_RETRY_TIMEOUT;
      out->timeoutMs = static_cast<int32_t>(
          std::min<uint64_t>(pending - static_cast<uint64_t>(now - record.lastCheckedMillis),
                              static_cast<uint64_t>(INT32_MAX)));
      return ScopedAStatus::ok();
    }

    uint64_t secureUserId, authenticatorId;
    if (!verifyPasswordHandle(enrolledPasswordHandle, providedPassword, &secureUserId,
                               &authenticatorId)) {
      record.failureCounter++;
      record.lastCheckedMillis = now;
      uint64_t newTimeout = computeRetryTimeout(record.failureCounter);
      if (newTimeout > 0) {
        out->statusCode = IGatekeeper::ERROR_RETRY_TIMEOUT;
        out->timeoutMs = static_cast<int32_t>(std::min<uint64_t>(newTimeout, static_cast<uint64_t>(INT32_MAX)));
        return ScopedAStatus::ok();
      }
      return gkError(IGatekeeper::ERROR_GENERAL_FAILURE);
    }

    if (deletedSecureUserIds_.count(secureUserId)) {
      return gkError(IGatekeeper::ERROR_GENERAL_FAILURE);
    }

    record.failureCounter = 0;
    record.lastCheckedMillis = 0;

    out->statusCode = IGatekeeper::STATUS_OK;
    out->timeoutMs = 0;
    HardwareAuthToken hat;
    hat.challenge = challenge;
    hat.userId = static_cast<int64_t>(secureUserId);
    hat.authenticatorId = static_cast<int64_t>(authenticatorId);
    hat.authenticatorType = HardwareAuthenticatorType::PASSWORD;
    hat.timestamp.milliSeconds = nowMillis();
    std::vector<uint8_t> macInput;
    macInput.push_back(0);
    putU64(&macInput, static_cast<uint64_t>(hat.challenge));
    putU64(&macInput, static_cast<uint64_t>(hat.userId));
    putU64(&macInput, static_cast<uint64_t>(hat.authenticatorId));
    putU32BE(&macInput, static_cast<uint32_t>(hat.authenticatorType));
    putU64BE(&macInput, static_cast<uint64_t>(hat.timestamp.milliSeconds));
    auto& st = hmacState();
    uint8_t key[32];
    {
      std::lock_guard<std::mutex> lg(st.mu);
      if (st.computed) {
        memcpy(key, st.hmacKey, sizeof(key));
      } else {
        klog("verify(): ISharedSecret negotiation not yet complete -- "
             "using the local placeholder HAT mac key");
        memcpy(key, kLocalMacKey, sizeof(key));
      }
    }
    hat.mac = hmacSha256(key, sizeof(key), macInput);
    out->hardwareAuthToken = hat;
    return ScopedAStatus::ok();
  }

 private:
  std::mutex mutex_;
  std::map<int32_t, uint64_t> nextAuthenticatorId_;
  std::map<uint64_t, FailureRecord> failureRecords_;
  std::map<int32_t, uint64_t> uidToSecureUserId_;
  std::set<uint64_t> deletedSecureUserIds_;
};

}

// register the gatekeeper and shared secret services
int main() {
  klog("main() entered");
  auto device = ndk::SharedRefBase::make<RhizoGatekeeper>();
  const std::string instance = std::string(RhizoGatekeeper::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(device->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    char buf[128];
    snprintf(buf, sizeof(buf), "addService FAILED status=%d", status);
    klog(buf);
    return 1;
  }
  auto sharedSecret = ndk::SharedRefBase::make<RhizoSharedSecret>();
  const std::string ssInstance = std::string(RhizoSharedSecret::descriptor) + "/gatekeeper";
  status = AServiceManager_addService(sharedSecret->asBinder().get(), ssInstance.c_str());
  if (status != STATUS_OK) {
    char buf[128];
    snprintf(buf, sizeof(buf), "ISharedSecret addService FAILED status=%d", status);
    klog(buf);
    return 1;
  }
  klog("registered (IGatekeeper/default + ISharedSecret/gatekeeper), joining thread pool");
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}

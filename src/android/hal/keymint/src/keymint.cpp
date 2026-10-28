#include "aidl/android/hardware/security/keymint/BnKeyMintDevice.h"
#include "aidl/android/hardware/security/keymint/BnKeyMintOperation.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <openssl/aes.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <sys/stat.h>
#include <vector>

using namespace aidl::android::hardware::security::keymint;
using aidl::android::hardware::security::secureclock::TimeStampToken;
using ndk::ScopedAStatus;

namespace {
constexpr int32_t kErrUnimplemented = -100;
constexpr int32_t kErrInvalidArgument = -38;
constexpr int32_t kErrInvalidKeyBlob = -33;
constexpr int32_t kErrVerificationFailed = -30;
constexpr int32_t kErrUnsupportedAlgorithm = -4;
constexpr int32_t kErrInvalidInputLength = -21;

// return a service-specific error status
ScopedAStatus kmError(int32_t code) { return ScopedAStatus::fromServiceSpecificError(code); }
// return the unimplemented error status
ScopedAStatus unimplemented() { return kmError(kErrUnimplemented); }

// write a message to the kernel log
void klog(const char* msg) {
  int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
  if (fd >= 0) { dprintf(fd, "<5>rhizo-keymint: %s\n", msg); close(fd); }
}

constexpr uint8_t kMasterKey[32] = {
    0x52, 0x68, 0x69, 0x7a, 0x6f, 0x2d, 0x4b, 0x65, 0x79, 0x4d, 0x69, 0x6e,
    0x74, 0x2d, 0x53, 0x77, 0x2d, 0x6f, 0x6e, 0x6c, 0x79, 0x2d, 0x6e, 0x6f,
    0x74, 0x2d, 0x66, 0x6f, 0x72, 0x2d, 0x70, 0x72};

// value type of a KeyParameter
enum class VKind : uint8_t { kInt, kLong, kBool, kBlob };

// return the value kind for a tag
VKind kindOfTag(int32_t tag) {
  uint32_t type = static_cast<uint32_t>(tag) & 0xF0000000u;
  switch (type) {
    case 0x10000000u: case 0x20000000u: case 0x30000000u: case 0x40000000u:
      return VKind::kInt;
    case 0x50000000u: case 0x60000000u: case 0xA0000000u:
      return VKind::kLong;
    case 0x70000000u:
      return VKind::kBool;
    default:
      return VKind::kBlob;
  }
}

// return the integer or enum value of a key parameter
int32_t getIntValue(const KeyParameter& p) {
  switch (p.value.getTag()) {
    case KeyParameterValue::algorithm: return static_cast<int32_t>(p.value.get<KeyParameterValue::algorithm>());
    case KeyParameterValue::blockMode: return static_cast<int32_t>(p.value.get<KeyParameterValue::blockMode>());
    case KeyParameterValue::paddingMode: return static_cast<int32_t>(p.value.get<KeyParameterValue::paddingMode>());
    case KeyParameterValue::digest: return static_cast<int32_t>(p.value.get<KeyParameterValue::digest>());
    case KeyParameterValue::keyPurpose: return static_cast<int32_t>(p.value.get<KeyParameterValue::keyPurpose>());
    case KeyParameterValue::integer: return p.value.get<KeyParameterValue::integer>();
    default: return 0;
  }
}

// return the blob value of a key parameter, or empty
std::vector<uint8_t> getBlobValue(const KeyParameter& p) {
  if (p.value.getTag() == KeyParameterValue::blob) return p.value.get<KeyParameterValue::blob>();
  return {};
}

// append a 32-bit value in little-endian order
void putU32(std::vector<uint8_t>* out, uint32_t v) {
  for (int i = 0; i < 4; i++) out->push_back(static_cast<uint8_t>(v >> (i * 8)));
}
// read a little-endian 32-bit value
uint32_t readU32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

// encrypt a key and parameters into a blob
std::vector<uint8_t> serializeBlob(const std::vector<uint8_t>& rawKey,
                                    const std::vector<KeyParameter>& params) {
  std::vector<uint8_t> plain;
  plain.push_back('R'); plain.push_back('Z'); plain.push_back('K'); plain.push_back('1');
  putU32(&plain, (uint32_t)rawKey.size());
  plain.insert(plain.end(), rawKey.begin(), rawKey.end());
  putU32(&plain, (uint32_t)params.size());
  for (const auto& p : params) {
    putU32(&plain, (uint32_t)p.tag);
    VKind k = kindOfTag(static_cast<int32_t>(p.tag));
    plain.push_back(static_cast<uint8_t>(k));
    switch (k) {
      case VKind::kInt: { putU32(&plain, (uint32_t)getIntValue(p)); break; }
      case VKind::kLong: {
        int64_t v = p.value.getTag() == KeyParameterValue::longInteger
                         ? p.value.get<KeyParameterValue::longInteger>()
                         : (p.value.getTag() == KeyParameterValue::dateTime
                                ? p.value.get<KeyParameterValue::dateTime>() : 0);
        putU32(&plain, (uint32_t)(v & 0xffffffffu));
        putU32(&plain, (uint32_t)((uint64_t)v >> 32));
        break;
      }
      case VKind::kBool: { plain.push_back(1); break; }
      case VKind::kBlob: {
        auto b = getBlobValue(p);
        putU32(&plain, (uint32_t)b.size());
        plain.insert(plain.end(), b.begin(), b.end());
        break;
      }
    }
  }
  std::vector<uint8_t> iv(12);
  RAND_bytes(iv.data(), (int)iv.size());
  std::vector<uint8_t> ct(plain.size());
  uint8_t tag[16];
  EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
  int outl = 0, total = 0;
  EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, kMasterKey, iv.data());
  EVP_EncryptUpdate(ctx, ct.data(), &outl, plain.data(), (int)plain.size());
  total += outl;
  EVP_EncryptFinal_ex(ctx, ct.data() + total, &outl);
  total += outl;
  EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag);
  EVP_CIPHER_CTX_free(ctx);
  std::vector<uint8_t> blob;
  blob.insert(blob.end(), iv.begin(), iv.end());
  blob.insert(blob.end(), ct.begin(), ct.begin() + total);
  blob.insert(blob.end(), tag, tag + 16);
  return blob;
}

// decrypt and parse a key blob
bool deserializeBlob(const std::vector<uint8_t>& blob, std::vector<uint8_t>* rawKey,
                      std::vector<KeyParameter>* params) {
  if (blob.size() < 12 + 16) return false;
  size_t ctLen = blob.size() - 12 - 16;
  const uint8_t* iv = blob.data();
  const uint8_t* ct = blob.data() + 12;
  const uint8_t* tag = blob.data() + 12 + ctLen;
  std::vector<uint8_t> plain(ctLen);
  EVP_CIPHER_CTX* ctx = EVP_CIPHER_CTX_new();
  int outl = 0, total = 0;
  EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, kMasterKey, iv);
  EVP_DecryptUpdate(ctx, plain.data(), &outl, ct, (int)ctLen);
  total += outl;
  EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, const_cast<uint8_t*>(tag));
  bool ok = EVP_DecryptFinal_ex(ctx, plain.data() + total, &outl) > 0;
  total += outl;
  EVP_CIPHER_CTX_free(ctx);
  if (!ok) return false;
  plain.resize(total);
  const uint8_t* p = plain.data();
  const uint8_t* end = p + plain.size();
  if (end - p < 8 || p[0] != 'R' || p[1] != 'Z' || p[2] != 'K' || p[3] != '1') return false;
  p += 4;
  uint32_t keyLen = readU32(p); p += 4;
  if ((size_t)(end - p) < keyLen) return false;
  rawKey->assign(p, p + keyLen); p += keyLen;
  if (end - p < 4) return false;
  uint32_t nParams = readU32(p); p += 4;
  params->clear();
  for (uint32_t i = 0; i < nParams; i++) {
    if (end - p < 5) return false;
    int32_t tagv = (int32_t)readU32(p); p += 4;
    VKind k = static_cast<VKind>(*p); p += 1;
    KeyParameter kp;
    kp.tag = static_cast<Tag>(tagv);
    switch (k) {
      case VKind::kInt: {
        if (end - p < 4) return false;
        int32_t v = (int32_t)readU32(p); p += 4;
        switch (kindOfTag(tagv) == VKind::kInt ? tagv : tagv) {
          default: break;
        }
        if (tagv == (int32_t)Tag::ALGORITHM) kp.value = KeyParameterValue::make<KeyParameterValue::algorithm>((Algorithm)v);
        else if (tagv == (int32_t)Tag::BLOCK_MODE) kp.value = KeyParameterValue::make<KeyParameterValue::blockMode>((BlockMode)v);
        else if (tagv == (int32_t)Tag::PADDING) kp.value = KeyParameterValue::make<KeyParameterValue::paddingMode>((PaddingMode)v);
        else if (tagv == (int32_t)Tag::DIGEST) kp.value = KeyParameterValue::make<KeyParameterValue::digest>((Digest)v);
        else if (tagv == (int32_t)Tag::PURPOSE) kp.value = KeyParameterValue::make<KeyParameterValue::keyPurpose>((KeyPurpose)v);
        else kp.value = KeyParameterValue::make<KeyParameterValue::integer>(v);
        break;
      }
      case VKind::kLong: {
        if (end - p < 8) return false;
        uint64_t lo = readU32(p); uint64_t hi = readU32(p + 4); p += 8;
        int64_t v = (int64_t)(lo | (hi << 32));
        kp.value = KeyParameterValue::make<KeyParameterValue::longInteger>(v);
        break;
      }
      case VKind::kBool: {
        if (end - p < 1) return false;
        p += 1;
        kp.value = KeyParameterValue::make<KeyParameterValue::boolValue>(true);
        break;
      }
      case VKind::kBlob: {
        if (end - p < 4) return false;
        uint32_t blen = readU32(p); p += 4;
        if ((size_t)(end - p) < blen) return false;
        std::vector<uint8_t> b(p, p + blen); p += blen;
        kp.value = KeyParameterValue::make<KeyParameterValue::blob>(std::move(b));
        break;
      }
    }
    params->push_back(std::move(kp));
  }
  return true;
}

// return the first parameter with the given tag, or null
const KeyParameter* findParam(const std::vector<KeyParameter>& params, Tag t) {
  for (auto& p : params) if (p.tag == t) return &p;
  return nullptr;
}

// return the AES cipher for a key size and block mode
const EVP_CIPHER* pickCipher(int32_t keySizeBits, BlockMode mode) {
  bool is256 = keySizeBits >= 256;
  switch (mode) {
    case BlockMode::GCM: return is256 ? EVP_aes_256_gcm() : EVP_aes_128_gcm();
    case BlockMode::CBC: return is256 ? EVP_aes_256_cbc() : EVP_aes_128_cbc();
    case BlockMode::ECB: return is256 ? EVP_aes_256_ecb() : EVP_aes_128_ecb();
    case BlockMode::CTR: return is256 ? EVP_aes_256_ctr() : EVP_aes_128_ctr();
    default: return nullptr;
  }
}

}

// KeyMint operation for AES
class RhizoOperation : public BnKeyMintOperation {
 public:
  // set up the cipher context for the key, mode and direction
  RhizoOperation(std::vector<uint8_t> key, BlockMode mode, bool encrypt, std::vector<uint8_t> iv,
                 int tagLenBytes = 16)
      : key_(std::move(key)), mode_(mode), encrypt_(encrypt), iv_(std::move(iv)),
        tagLenBytes_(tagLenBytes) {
    ctx_ = EVP_CIPHER_CTX_new();
    const EVP_CIPHER* cipher = pickCipher((int32_t)key_.size() * 8, mode_);
    if (cipher) {
      if (encrypt_)
        EVP_EncryptInit_ex(ctx_, cipher, nullptr, key_.data(), iv_.empty() ? nullptr : iv_.data());
      else
        EVP_DecryptInit_ex(ctx_, cipher, nullptr, key_.data(), iv_.empty() ? nullptr : iv_.data());
      valid_ = true;
    }
  }
  // free the cipher context
  ~RhizoOperation() override { if (ctx_) EVP_CIPHER_CTX_free(ctx_); }

  // feed additional authenticated data to the cipher
  ScopedAStatus updateAad(const std::vector<uint8_t>& aad, const std::optional<HardwareAuthToken>&,
                           const std::optional<TimeStampToken>&) override {
    if (!valid_) return kmError(kErrInvalidKeyBlob);
    int outl = 0;
    std::lock_guard<std::mutex> lg(mu_);
    if (encrypt_) EVP_EncryptUpdate(ctx_, nullptr, &outl, aad.data(), (int)aad.size());
    else EVP_DecryptUpdate(ctx_, nullptr, &outl, aad.data(), (int)aad.size());
    return ScopedAStatus::ok();
  }

  // process input data for the operation
  ScopedAStatus update(const std::vector<uint8_t>& input, const std::optional<HardwareAuthToken>&,
                        const std::optional<TimeStampToken>&, std::vector<uint8_t>* out) override {
    if (!valid_) return kmError(kErrInvalidKeyBlob);
    std::lock_guard<std::mutex> lg(mu_);
    if (mode_ == BlockMode::GCM && !encrypt_) {
      pending_.insert(pending_.end(), input.begin(), input.end());
      out->clear();
      return ScopedAStatus::ok();
    }
    out->resize(input.size() + 32);
    int outl = 0;
    int rc = encrypt_ ? EVP_EncryptUpdate(ctx_, out->data(), &outl, input.data(), (int)input.size())
                       : EVP_DecryptUpdate(ctx_, out->data(), &outl, input.data(), (int)input.size());
    if (rc != 1) { out->clear(); return kmError(kErrInvalidArgument); }
    out->resize(outl);
    return ScopedAStatus::ok();
  }

  // finish the operation and return the output
  ScopedAStatus finish(const std::optional<std::vector<uint8_t>>& input,
                        const std::optional<std::vector<uint8_t>>&,
                        const std::optional<HardwareAuthToken>&, const std::optional<TimeStampToken>&,
                        const std::optional<std::vector<uint8_t>>&, std::vector<uint8_t>* out) override {
    if (!valid_) return kmError(kErrInvalidKeyBlob);
    std::lock_guard<std::mutex> lg(mu_);
    if (mode_ == BlockMode::GCM && !encrypt_) {
      if (input.has_value() && !input->empty())
        pending_.insert(pending_.end(), input->begin(), input->end());
      int tagLen = tagLenBytes_ > 16 ? 16 : tagLenBytes_;
      if ((int)pending_.size() < tagLen) { valid_ = false; return kmError(kErrInvalidInputLength); }
      size_t ctLen = pending_.size() - tagLen;
      const uint8_t* tag = pending_.data() + ctLen;
      EVP_CIPHER_CTX_ctrl(ctx_, EVP_CTRL_GCM_SET_TAG, tagLen, const_cast<uint8_t*>(tag));
      out->resize(ctLen + 32);
      int outl = 0, total = 0;
      if (ctLen > 0) {
        int rc = EVP_DecryptUpdate(ctx_, out->data(), &outl, pending_.data(), (int)ctLen);
        if (rc != 1) { valid_ = false; out->clear(); return kmError(kErrInvalidArgument); }
        total += outl;
      }
      int rc = EVP_DecryptFinal_ex(ctx_, out->data() + total, &outl);
      valid_ = false;
      if (rc != 1) { out->clear(); return kmError(kErrVerificationFailed); }
      total += outl;
      out->resize(total);
      return ScopedAStatus::ok();
    }
    std::vector<uint8_t> tail;
    if (input.has_value() && !input->empty()) {
      tail.resize(input->size() + 32);
      int outl = 0;
      int rc = encrypt_ ? EVP_EncryptUpdate(ctx_, tail.data(), &outl, input->data(), (int)input->size())
                         : EVP_DecryptUpdate(ctx_, tail.data(), &outl, input->data(), (int)input->size());
      if (rc != 1) return kmError(kErrInvalidArgument);
      tail.resize(outl);
    }
    out->insert(out->end(), tail.begin(), tail.end());
    int outl = 0;
    uint8_t finalBuf[32];
    int rc = encrypt_ ? EVP_EncryptFinal_ex(ctx_, finalBuf, &outl) : EVP_DecryptFinal_ex(ctx_, finalBuf, &outl);
    if (rc != 1) { valid_ = false; return kmError(kErrVerificationFailed); }
    out->insert(out->end(), finalBuf, finalBuf + outl);
    if (mode_ == BlockMode::GCM && encrypt_) {
      uint8_t tag[16];
      int n = tagLenBytes_ > 16 ? 16 : tagLenBytes_;
      EVP_CIPHER_CTX_ctrl(ctx_, EVP_CTRL_GCM_GET_TAG, n, tag);
      out->insert(out->end(), tag, tag + n);
    }
    valid_ = false;
    return ScopedAStatus::ok();
  }

  // mark the operation invalid
  ScopedAStatus abort() override {
    std::lock_guard<std::mutex> lg(mu_);
    valid_ = false;
    return ScopedAStatus::ok();
  }

 private:
  std::vector<uint8_t> key_;
  BlockMode mode_;
  bool encrypt_;
  std::vector<uint8_t> iv_;
  int tagLenBytes_;
  std::vector<uint8_t> pending_;
  EVP_CIPHER_CTX* ctx_ = nullptr;
  bool valid_ = false;
  std::mutex mu_;
};

class RhizoKeyMintDevice : public BnKeyMintDevice {
 public:
  // fill in the KeyMint hardware info
  ScopedAStatus getHardwareInfo(KeyMintHardwareInfo* out) override {
    out->versionNumber = 4;
    out->securityLevel = SecurityLevel::SOFTWARE;
    out->keyMintName = "RhizoSoftwareKeyMint";
    out->keyMintAuthorName = "Rhizo";
    out->timestampTokenRequired = false;
    return ScopedAStatus::ok();
  }

  // ignore the extra entropy
  ScopedAStatus addRngEntropy(const std::vector<uint8_t>&) override { return ScopedAStatus::ok(); }

  // generate a random AES key and return its blob
  ScopedAStatus generateKey(const std::vector<KeyParameter>& params,
                             const std::optional<AttestationKey>&, KeyCreationResult* out) override {
    const KeyParameter* alg = findParam(params, Tag::ALGORITHM);
    if (!alg || (Algorithm)getIntValue(*alg) != Algorithm::AES) {
      klog("generateKey: only AES supported in this build");
      return kmError(kErrUnsupportedAlgorithm);
    }
    const KeyParameter* ksz = findParam(params, Tag::KEY_SIZE);
    int32_t bits = ksz ? getIntValue(*ksz) : 256;
    std::vector<uint8_t> key(bits / 8);
    RAND_bytes(key.data(), (int)key.size());
    out->keyBlob = serializeBlob(key, params);
    out->keyCharacteristics.resize(1);
    out->keyCharacteristics[0].securityLevel = SecurityLevel::SOFTWARE;
    out->keyCharacteristics[0].authorizations = params;
    klog("generateKey: AES key generated");
    return ScopedAStatus::ok();
  }

  // wrap imported AES key data in a key blob
  ScopedAStatus importKey(const std::vector<KeyParameter>& params, KeyFormat,
                           const std::vector<uint8_t>& keyData, const std::optional<AttestationKey>&,
                           KeyCreationResult* out) override {
    const KeyParameter* alg = findParam(params, Tag::ALGORITHM);
    if (!alg || (Algorithm)getIntValue(*alg) != Algorithm::AES) {
      klog("importKey: only AES supported in this build");
      return kmError(kErrUnsupportedAlgorithm);
    }
    out->keyBlob = serializeBlob(keyData, params);
    out->keyCharacteristics.resize(1);
    out->keyCharacteristics[0].securityLevel = SecurityLevel::SOFTWARE;
    out->keyCharacteristics[0].authorizations = params;
    klog("importKey: AES key imported");
    return ScopedAStatus::ok();
  }

  // report that wrapped key import is unimplemented
  ScopedAStatus importWrappedKey(const std::vector<uint8_t>&, const std::vector<uint8_t>&,
                                  const std::vector<uint8_t>&, const std::vector<KeyParameter>&,
                                  int64_t, int64_t, KeyCreationResult*) override { return unimplemented(); }
  // copy the key blob to the output
  ScopedAStatus upgradeKey(const std::vector<uint8_t>& keyBlob, const std::vector<KeyParameter>&,
                            std::vector<uint8_t>* out) override {
    *out = keyBlob;
    return ScopedAStatus::ok();
  }
  // ignore the key deletion
  ScopedAStatus deleteKey(const std::vector<uint8_t>&) override { return ScopedAStatus::ok(); }
  // ignore deleting all keys
  ScopedAStatus deleteAllKeys() override { return ScopedAStatus::ok(); }
  // report that destroying attestation ids is unimplemented
  ScopedAStatus destroyAttestationIds() override { return unimplemented(); }

  // start a cipher operation on a key blob
  ScopedAStatus begin(KeyPurpose purpose, const std::vector<uint8_t>& keyBlob,
                       const std::vector<KeyParameter>& inParams, const std::optional<HardwareAuthToken>&,
                       BeginResult* out) override {
    std::vector<uint8_t> key;
    std::vector<KeyParameter> stored;
    if (!deserializeBlob(keyBlob, &key, &stored)) {
      klog("begin: invalid/forged keyBlob");
      return kmError(kErrInvalidKeyBlob);
    }
    const KeyParameter* bm = findParam(inParams, Tag::BLOCK_MODE);
    BlockMode mode = bm ? (BlockMode)getIntValue(*bm) : BlockMode::GCM;
    bool encrypt = (purpose == KeyPurpose::ENCRYPT);
    std::vector<uint8_t> iv;
    const KeyParameter* callerNonce = findParam(inParams, Tag::NONCE);
    if (callerNonce) {
      iv = getBlobValue(*callerNonce);
    } else if (mode != BlockMode::ECB) {
      iv.resize(mode == BlockMode::GCM ? 12 : 16);
      RAND_bytes(iv.data(), (int)iv.size());
      KeyParameter nonceParam;
      nonceParam.tag = Tag::NONCE;
      nonceParam.value = KeyParameterValue::make<KeyParameterValue::blob>(iv);
      out->params.push_back(std::move(nonceParam));
    }
    const KeyParameter* macLen = findParam(inParams, Tag::MAC_LENGTH);
    int tagLenBytes = macLen ? (getIntValue(*macLen) / 8) : 16;
    out->challenge = 0;
    out->operation = ndk::SharedRefBase::make<RhizoOperation>(std::move(key), mode, encrypt, iv, tagLenBytes);
    klog("begin: operation started");
    return ScopedAStatus::ok();
  }

  // ignore the device lock state
  ScopedAStatus deviceLocked(bool, const std::optional<TimeStampToken>&) override { return ScopedAStatus::ok(); }
  // ignore the end of early boot
  ScopedAStatus earlyBootEnded() override { return ScopedAStatus::ok(); }

  // report that storage key conversion is unimplemented
  ScopedAStatus convertStorageKeyToEphemeral(const std::vector<uint8_t>&,
                                              std::vector<uint8_t>*) override { return unimplemented(); }
  // return the stored parameters of a key blob
  ScopedAStatus getKeyCharacteristics(const std::vector<uint8_t>& keyBlob, const std::vector<uint8_t>&,
                                       const std::vector<uint8_t>&,
                                       std::vector<KeyCharacteristics>* out) override {
    std::vector<uint8_t> key;
    std::vector<KeyParameter> stored;
    if (!deserializeBlob(keyBlob, &key, &stored)) return kmError(kErrInvalidKeyBlob);
    out->resize(1);
    (*out)[0].securityLevel = SecurityLevel::SOFTWARE;
    (*out)[0].authorizations = stored;
    return ScopedAStatus::ok();
  }
  // report that the root of trust challenge is unimplemented
  ScopedAStatus getRootOfTrustChallenge(std::array<uint8_t, 16>*) override { return unimplemented(); }
  // report that the root of trust is unimplemented
  ScopedAStatus getRootOfTrust(const std::array<uint8_t, 16>&, std::vector<uint8_t>*) override { return unimplemented(); }
  // ignore the root of trust
  ScopedAStatus sendRootOfTrust(const std::vector<uint8_t>&) override { return ScopedAStatus::ok(); }
  // ignore the additional attestation info
  ScopedAStatus setAdditionalAttestationInfo(const std::vector<KeyParameter>&) override { return ScopedAStatus::ok(); }
};

// register the keymint device and join the binder thread pool
int main() {
  klog("main() entered");
  try {
    auto device = ndk::SharedRefBase::make<RhizoKeyMintDevice>();
    klog("device object constructed");
    const std::string instance = std::string(RhizoKeyMintDevice::descriptor) + "/default";
    klog(("registering as " + instance).c_str());
    binder_status_t status = AServiceManager_addService(device->asBinder().get(), instance.c_str());
    if (status != STATUS_OK) {
      char buf[128];
      snprintf(buf, sizeof(buf), "addService FAILED status=%d", status);
      klog(buf);
      return 1;
    }
    klog("registered, joining thread pool");
    ABinderProcess_setThreadPoolMaxThreadCount(0);
    ABinderProcess_joinThreadPool();
    klog("joinThreadPool RETURNED (unexpected)");
    return 0;
  } catch (const std::exception& e) {
    klog((std::string("EXCEPTION: ") + e.what()).c_str());
    return 2;
  } catch (...) {
    klog("UNKNOWN EXCEPTION");
    return 3;
  }
}

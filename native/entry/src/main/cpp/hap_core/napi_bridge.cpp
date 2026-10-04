#include "zip_reader.h"
#include "signing_block.h"

#include <napi/native_api.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <exception>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" int qingqi_sign_hap(const char* input, const char* output,
                                const char* private_key, const char* certificates,
                                const char* profile, char* error_buffer,
                                size_t error_capacity);
extern "C" int qingqi_key_matches_certificate(const char* private_key,
                                                 const char* certificate,
                                                 char* error_buffer,
                                                 size_t error_capacity);
extern "C" int qingqi_certificate_fingerprint(const char* certificate,
                                                unsigned char* output, size_t output_capacity,
                                                char* error_buffer, size_t error_capacity);
extern "C" int qingqi_generate_csr(const char* private_key_pem,
                                    unsigned char* output, size_t output_capacity,
                                    size_t* output_length, char* error_buffer,
                                    size_t error_capacity);
extern "C" int qingqi_read_signed_profile(const char* profile_path,
                                            unsigned char* output, size_t output_capacity,
                                            size_t* output_length, char* error_buffer,
                                            size_t error_capacity);
extern "C" int qingqi_read_install_permissions(const char* input,
                                                unsigned char* output, size_t capacity,
                                                size_t* length, char* error, size_t error_capacity);
extern "C" int qingqi_profile_matches_certificate(const char* profile_path,
                                                     const char* certificate_path);
extern "C" int qingqi_verify_hap(const char* file_path, char* error_buffer,
                                   size_t error_capacity);
extern "C" int qingqi_hdc_disconnect(char* error_buffer, size_t error_capacity);
extern "C" int qingqi_hdc_install_progress(const char* file_path, uint32_t reset,
                                            unsigned char* output, size_t capacity,
                                            size_t* length);

extern "C" int qingqi_hdc_command(const char* key_root, uint16_t port,
                                  uint32_t operation, const char* parameter,
                                  unsigned char* output, size_t output_capacity,
                                  size_t* output_length, char* error_buffer,
                                  size_t error_capacity);

namespace {

napi_value ReadManifest(napi_env env, napi_callback_info info, bool pack_info) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected a HAP path");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid HAP path");
    return nullptr;
  }
  std::vector<char> path_bytes(length + 1);
  if (napi_get_value_string_utf8(env, arg, path_bytes.data(), path_bytes.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid HAP path");
    return nullptr;
  }
  try {
    const auto manifest = pack_info ?
      qingqi::hap::ReadPackInfo(std::string(path_bytes.data(), length)) :
      qingqi::hap::ReadModuleJson(std::string(path_bytes.data(), length));
    napi_value result = nullptr;
    if (napi_create_string_utf8(env, manifest.c_str(), manifest.size(), &result) != napi_ok) {
      napi_throw_error(env, nullptr, "Cannot return HAP manifest");
      return nullptr;
    }
    return result;
  } catch (const std::exception& error) {
    napi_throw_error(env, "HAP_INSPECT", error.what());
    return nullptr;
  }
}

napi_value ReadModule(napi_env env, napi_callback_info info) {
  return ReadManifest(env, info, false);
}

napi_value ReadPack(napi_env env, napi_callback_info info) {
  return ReadManifest(env, info, true);
}

// Only reports whether a structurally valid HAP signing block exists. It does
// not claim that its signature or device authorization has been verified.
napi_value HasSigningBlock(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected a HAP path");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid HAP path");
    return nullptr;
  }
  std::vector<char> path(length + 1);
  if (napi_get_value_string_utf8(env, arg, path.data(), path.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid HAP path");
    return nullptr;
  }
  bool signed_block = false;
  try {
    qingqi::hap::InspectSigningBlock(std::string(path.data(), length));
    signed_block = true;
  } catch (const std::exception&) {}
  napi_value result = nullptr;
  napi_get_boolean(env, signed_block, &result);
  return result;
}

// Returns the app icon bytes embedded in a local HAP, or an empty ArrayBuffer
// when the package has no readable icon. A missing icon is normal, so it is not
// reported as an error: the caller falls back to a placeholder.
napi_value ReadIcon(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2]{};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
    napi_throw_type_error(env, nullptr, "Expected a HAP path and an icon name");
    return nullptr;
  }
  std::array<std::string, 2> values;
  for (size_t i = 0; i < argc; ++i) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &length) != napi_ok) {
      napi_throw_type_error(env, nullptr, "Invalid HAP icon argument");
      return nullptr;
    }
    // The icon name is short; the path uses the same bound as the manifest reader.
    const size_t limit = i == 0 ? 4096 : 256;
    if (length > limit) {
      napi_throw_type_error(env, nullptr, "Invalid HAP icon argument");
      return nullptr;
    }
    std::vector<char> buffer(length + 1);
    if (napi_get_value_string_utf8(env, args[i], buffer.data(), buffer.size(), &length) != napi_ok) {
      napi_throw_type_error(env, nullptr, "Invalid HAP icon argument");
      return nullptr;
    }
    values[i].assign(buffer.data(), length);
  }
  try {
    const auto bytes = qingqi::hap::ReadHapIcon(values[0], values[1]);
    void* data = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, bytes.size(), &data, &buffer) != napi_ok) {
      napi_throw_error(env, nullptr, "Cannot allocate HAP icon buffer");
      return nullptr;
    }
    if (!bytes.empty()) {
      std::memcpy(data, bytes.data(), bytes.size());
    }
    // Hand ArkTS a Uint8Array over that buffer; Uint8Array.buffer gives the
    // ArrayBuffer back, so callers can use either shape.
    napi_value result = nullptr;
    if (napi_create_typedarray(env, napi_uint8_array, bytes.size(), buffer, 0, &result) != napi_ok) {
      napi_throw_error(env, nullptr, "Cannot return HAP icon");
      return nullptr;
    }
    return result;
  } catch (const std::exception& error) {
    napi_throw_error(env, "HAP_ICON", error.what());
    return nullptr;
  }
}

napi_value ReadArchiveFile(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2]{};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
    napi_throw_type_error(env, nullptr, "Expected a HAP path and an icon name");
    return nullptr;
  }
  std::array<std::string, 2> values;
  for (size_t i = 0; i < argc; ++i) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &length) != napi_ok) {
      napi_throw_type_error(env, nullptr, "Invalid HAP icon argument");
      return nullptr;
    }
    // The icon name is short; the path uses the same bound as the manifest reader.
    const size_t limit = i == 0 ? 4096 : 1024;
    if (length > limit) {
      napi_throw_type_error(env, nullptr, "Invalid HAP icon argument");
      return nullptr;
    }
    std::vector<char> buffer(length + 1);
    if (napi_get_value_string_utf8(env, args[i], buffer.data(), buffer.size(), &length) != napi_ok) {
      napi_throw_type_error(env, nullptr, "Invalid HAP icon argument");
      return nullptr;
    }
    values[i].assign(buffer.data(), length);
  }
  try {
    const auto bytes = qingqi::hap::ReadEntryBytes(values[0], values[1], 4 * 1024 * 1024);
    void* data = nullptr;
    napi_value buffer = nullptr;
    if (napi_create_arraybuffer(env, bytes.size(), &data, &buffer) != napi_ok) {
      napi_throw_error(env, nullptr, "Cannot allocate HAP icon buffer");
      return nullptr;
    }
    if (!bytes.empty()) {
      std::memcpy(data, bytes.data(), bytes.size());
    }
    // Hand ArkTS a Uint8Array over that buffer; Uint8Array.buffer gives the
    // ArrayBuffer back, so callers can use either shape.
    napi_value result = nullptr;
    if (napi_create_typedarray(env, napi_uint8_array, bytes.size(), buffer, 0, &result) != napi_ok) {
      napi_throw_error(env, nullptr, "Cannot return HAP icon");
      return nullptr;
    }
    return result;
  } catch (const std::exception& error) {
    napi_throw_error(env, "HAP_ICON", error.what());
    return nullptr;
  }
}

napi_value MatchMaterialPair(napi_env env, napi_callback_info info, bool profile) {
  size_t argc = 2;
  napi_value args[2]{};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
    napi_throw_type_error(env, nullptr, "Expected key and certificate paths");
    return nullptr;
  }
  std::array<std::string, 2> paths;
  for (size_t i = 0; i < argc; ++i) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > 4096) {
      napi_throw_type_error(env, nullptr, "Invalid signing material path");
      return nullptr;
    }
    std::vector<char> buffer(length + 1);
    if (napi_get_value_string_utf8(env, args[i], buffer.data(), buffer.size(), &length) != napi_ok) {
      napi_throw_type_error(env, nullptr, "Invalid signing material path");
      return nullptr;
    }
    paths[i].assign(buffer.data(), length);
  }
  // 失败原因要带出来：只回一句 "Cannot verify..." 时，上层无法区分
  // 「确实不配对」和「材料读不了」，排查只能靠改代码重编。
  std::array<char, 512> failure{};
  failure[0] = '\0';
  const int result = profile ?
    qingqi_profile_matches_certificate(paths[0].c_str(), paths[1].c_str()) :
    qingqi_key_matches_certificate(paths[0].c_str(), paths[1].c_str(),
                                   failure.data(), failure.size());
  if (result < 0) {
    const std::string detail = failure[0] != '\0' ?
      std::string("Cannot verify key and certificate: ") + failure.data() :
      std::string("Cannot verify key and certificate");
    napi_throw_error(env, "SIGNING_MATERIAL", detail.c_str());
    return nullptr;
  }
  napi_value matched = nullptr;
  napi_get_boolean(env, result == 1, &matched);
  return matched;
}

napi_value KeyMatchesCertificate(napi_env env, napi_callback_info info) {
  return MatchMaterialPair(env, info, false);
}

napi_value CertificateFingerprint(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected a certificate path");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid certificate path");
    return nullptr;
  }
  std::vector<char> path(length + 1);
  if (napi_get_value_string_utf8(env, arg, path.data(), path.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid certificate path");
    return nullptr;
  }
  std::array<unsigned char, 65> output{};
  std::array<char, 256> error{};
  if (qingqi_certificate_fingerprint(path.data(), output.data(), output.size(),
                                    error.data(), error.size()) != 0) {
    napi_throw_error(env, "SIGNING_MATERIAL", error.data());
    return nullptr;
  }
  napi_value result = nullptr;
  napi_create_string_utf8(env, reinterpret_cast<const char*>(output.data()), 64, &result);
  return result;
}

napi_value ProfileMatchesCertificate(napi_env env, napi_callback_info info) {
  return MatchMaterialPair(env, info, true);
}

napi_value ReadVerifiedJson(napi_env env, napi_callback_info info, bool permissions) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected a file path");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid file path");
    return nullptr;
  }
  std::vector<char> path(length + 1);
  if (napi_get_value_string_utf8(env, arg, path.data(), path.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid file path");
    return nullptr;
  }
  std::vector<unsigned char> content(256 * 1024);
  size_t content_length = 0;
  std::array<char, 1024> error{};
  const auto reader = permissions ? qingqi_read_install_permissions : qingqi_read_signed_profile;
  if (reader(path.data(), content.data(), content.size(), &content_length,
             error.data(), error.size()) != 0) {
    napi_throw_error(env, permissions ? "HAP_INSPECT" : "PROFILE_VERIFY", error.data());
    return nullptr;
  }
  napi_value result = nullptr;
  if (napi_create_string_utf8(env, reinterpret_cast<const char*>(content.data()),
                              content_length, &result) != napi_ok) {
    napi_throw_error(env, nullptr, "Cannot return verified profile");
    return nullptr;
  }
  return result;
}

napi_value ReadSignedProfile(napi_env env, napi_callback_info info) {
  return ReadVerifiedJson(env, info, false);
}

napi_value ReadInstallPermissions(napi_env env, napi_callback_info info) {
  return ReadVerifiedJson(env, info, true);
}

napi_value GenerateCsr(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected a PKCS#8 private key");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid private key length");
    return nullptr;
  }
  std::vector<char> key(length + 1);
  if (napi_get_value_string_utf8(env, arg, key.data(), key.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid private key text");
    return nullptr;
  }
  std::array<unsigned char, 8192> csr{};
  size_t csr_length = 0;
  std::array<char, 256> error{};
  const int status = qingqi_generate_csr(key.data(), csr.data(), csr.size(),
                                         &csr_length, error.data(), error.size());
  std::fill(key.begin(), key.end(), '\0');
  if (status != 0) {
    napi_throw_error(env, "CSR_GENERATION", error[0] ? error.data() : "Cannot generate CSR");
    return nullptr;
  }
  napi_value result = nullptr;
  if (napi_create_string_utf8(env, reinterpret_cast<const char*>(csr.data()),
                              csr_length, &result) != napi_ok) {
    napi_throw_error(env, nullptr, "Cannot return CSR");
    return nullptr;
  }
  return result;
}

struct SignWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::array<std::string, 5> paths;
  std::array<char, 1024> error{};
  int result = 1;
};

struct VerifyWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string path;
  std::array<char, 1024> error{};
  int result = 1;
};

struct HdcWork {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string key_root;
  std::string parameter;
  uint32_t operation = 0;
  std::vector<unsigned char> output = std::vector<unsigned char>(1024 * 1024);
  size_t output_length = 0;
  std::array<char, 1024> error{};
  int result = 1;
};

napi_value HdcCommand(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3]{};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 3) {
    napi_throw_type_error(env, nullptr, "Expected HDC key root, operation and parameter");
    return nullptr;
  }
  auto* state = new HdcWork();
  size_t length = 0;
  if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    delete state;
    napi_throw_type_error(env, nullptr, "Invalid HDC key root");
    return nullptr;
  }
  std::vector<char> root(length + 1);
  if (napi_get_value_string_utf8(env, args[0], root.data(), root.size(), &length) != napi_ok ||
      napi_get_value_uint32(env, args[1], &state->operation) != napi_ok ||
      state->operation > 14 ||
      napi_get_value_string_utf8(env, args[2], nullptr, 0, &length) != napi_ok ||
      length > 4096) {
    delete state;
    napi_throw_type_error(env, nullptr, "Invalid HDC operation");
    return nullptr;
  }
  state->key_root = root.data();
  std::vector<char> parameter(length + 1);
  if (napi_get_value_string_utf8(env, args[2], parameter.data(), parameter.size(), &length) != napi_ok) {
    delete state;
    napi_throw_type_error(env, nullptr, "Invalid HDC parameter");
    return nullptr;
  }
  state->parameter.assign(parameter.data(), length);
  napi_value promise = nullptr;
  if (napi_create_promise(env, &state->deferred, &promise) != napi_ok) {
    delete state;
    napi_throw_error(env, nullptr, "Cannot create HDC task");
    return nullptr;
  }
  napi_value name = nullptr;
  napi_create_string_utf8(env, "qingqiHdcCommand", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name,
      [](napi_env, void* data) {
        auto* task = static_cast<HdcWork*>(data);
        task->result = qingqi_hdc_command(task->key_root.c_str(), 38710,
          task->operation, task->parameter.empty() ? nullptr : task->parameter.c_str(),
          task->output.data(), task->output.size(), &task->output_length,
          task->error.data(), task->error.size());
      },
      [](napi_env env, napi_status status, void* data) {
        auto* task = static_cast<HdcWork*>(data);
        if (status == napi_ok && task->result == 0) {
          napi_value value = nullptr;
          napi_create_string_utf8(env,
            reinterpret_cast<const char*>(task->output.data()), task->output_length, &value);
          napi_resolve_deferred(env, task->deferred, value);
        } else {
          napi_value message = nullptr;
          napi_value error = nullptr;
          const char* detail = task->error[0] ? task->error.data() : "HDC operation failed";
          napi_create_string_utf8(env, detail, NAPI_AUTO_LENGTH, &message);
          napi_create_error(env, nullptr, message, &error);
          napi_reject_deferred(env, task->deferred, error);
        }
        napi_delete_async_work(env, task->work);
        delete task;
      }, state, &state->work) != napi_ok ||
      napi_queue_async_work(env, state->work) != napi_ok) {
    if (state->work) napi_delete_async_work(env, state->work);
    delete state;
    napi_throw_error(env, nullptr, "Cannot queue HDC task");
    return nullptr;
  }
  return promise;
}

napi_value HdcDisconnect(napi_env env, napi_callback_info info) {
  // 断开是一次性的轻操作，同步做完即可；失败也不抛错，只回报数量，
  // 界面按「已断开」处理就好 —— 让用户为一个释放动作处理异常没有意义。
  std::string error(256, '\0');
  const int dropped = qingqi_hdc_disconnect(error.data(), error.size());
  napi_value value = nullptr;
  napi_create_int32(env, dropped < 0 ? 0 : dropped, &value);
  return value;
}

napi_value VerifyHap(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected signed HAP path");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid signed HAP path");
    return nullptr;
  }
  std::vector<char> path(length + 1);
  if (napi_get_value_string_utf8(env, arg, path.data(), path.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid signed HAP path");
    return nullptr;
  }
  auto* state = new VerifyWork();
  state->path.assign(path.data(), length);
  napi_value promise = nullptr;
  if (napi_create_promise(env, &state->deferred, &promise) != napi_ok) {
    delete state;
    napi_throw_error(env, nullptr, "Cannot create verification task");
    return nullptr;
  }
  napi_value name = nullptr;
  napi_create_string_utf8(env, "qingqiVerifyHap", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name,
      [](napi_env, void* data) {
        auto* task = static_cast<VerifyWork*>(data);
        task->result = qingqi_verify_hap(task->path.c_str(), task->error.data(),
                                         task->error.size());
      },
      [](napi_env env, napi_status status, void* data) {
        auto* task = static_cast<VerifyWork*>(data);
        if (status == napi_ok && task->result == 0) {
          napi_value value = nullptr;
          napi_get_undefined(env, &value);
          napi_resolve_deferred(env, task->deferred, value);
        } else {
          napi_value message = nullptr;
          napi_value error = nullptr;
          const char* detail = task->error[0] ? task->error.data() : "HAP verification failed";
          napi_create_string_utf8(env, detail, NAPI_AUTO_LENGTH, &message);
          napi_create_error(env, nullptr, message, &error);
          napi_reject_deferred(env, task->deferred, error);
        }
        napi_delete_async_work(env, task->work);
        delete task;
      }, state, &state->work) != napi_ok ||
      napi_queue_async_work(env, state->work) != napi_ok) {
    if (state->work) napi_delete_async_work(env, state->work);
    delete state;
    napi_throw_error(env, nullptr, "Cannot queue verification task");
    return nullptr;
  }
  return promise;
}

napi_value SignHap(napi_env env, napi_callback_info info) {
  size_t argc = 5;
  napi_value args[5]{};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 5) {
    napi_throw_type_error(env, nullptr, "Expected five signing paths");
    return nullptr;
  }
  auto* state = new SignWork();
  for (size_t i = 0; i < argc; ++i) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > 4096) {
      delete state;
      napi_throw_type_error(env, nullptr, "Invalid signing path");
      return nullptr;
    }
    std::vector<char> buffer(length + 1);
    if (napi_get_value_string_utf8(env, args[i], buffer.data(), buffer.size(), &length) != napi_ok) {
      delete state;
      napi_throw_type_error(env, nullptr, "Invalid signing path");
      return nullptr;
    }
    state->paths[i].assign(buffer.data(), length);
  }
  napi_value promise = nullptr;
  if (napi_create_promise(env, &state->deferred, &promise) != napi_ok) {
    delete state;
    napi_throw_error(env, nullptr, "Cannot create signing task");
    return nullptr;
  }
  napi_value name = nullptr;
  napi_create_string_utf8(env, "qingqiSignHap", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name,
      [](napi_env, void* data) {
        auto* task = static_cast<SignWork*>(data);
        task->result = qingqi_sign_hap(
          task->paths[0].c_str(), task->paths[1].c_str(), task->paths[2].c_str(),
          task->paths[3].c_str(), task->paths[4].c_str(),
          task->error.data(), task->error.size());
      },
      [](napi_env env, napi_status status, void* data) {
        auto* task = static_cast<SignWork*>(data);
        if (status == napi_ok && task->result == 0) {
          napi_value value = nullptr;
          napi_get_undefined(env, &value);
          napi_resolve_deferred(env, task->deferred, value);
        } else {
          napi_value message = nullptr;
          napi_value error = nullptr;
          const char* detail = task->error[0] ? task->error.data() : "HAP signing failed";
          napi_create_string_utf8(env, detail, NAPI_AUTO_LENGTH, &message);
          napi_create_error(env, nullptr, message, &error);
          napi_reject_deferred(env, task->deferred, error);
        }
        napi_delete_async_work(env, task->work);
        delete task;
      }, state, &state->work) != napi_ok ||
      napi_queue_async_work(env, state->work) != napi_ok) {
    if (state->work) napi_delete_async_work(env, state->work);
    delete state;
    napi_throw_error(env, nullptr, "Cannot queue signing task");
    return nullptr;
  }
  return promise;
}

napi_value ExtractPackage(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3]{};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 3) {
    napi_throw_type_error(env, nullptr, "Expected archive, entry and output");
    return nullptr;
  }
  auto* state = new SignWork();
  for (size_t i = 0; i < argc; ++i) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, args[i], nullptr, 0, &length) != napi_ok ||
        length == 0 || length > 4096) {
      delete state;
      napi_throw_type_error(env, nullptr, "Invalid signing path");
      return nullptr;
    }
    std::vector<char> buffer(length + 1);
    if (napi_get_value_string_utf8(env, args[i], buffer.data(), buffer.size(), &length) != napi_ok) {
      delete state;
      napi_throw_type_error(env, nullptr, "Invalid signing path");
      return nullptr;
    }
    state->paths[i].assign(buffer.data(), length);
  }
  napi_value promise = nullptr;
  if (napi_create_promise(env, &state->deferred, &promise) != napi_ok) {
    delete state;
    napi_throw_error(env, nullptr, "Cannot create signing task");
    return nullptr;
  }
  napi_value name = nullptr;
  napi_create_string_utf8(env, "qingqiExtractPackage", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, nullptr, name,
      [](napi_env, void* data) {
        auto* task = static_cast<SignWork*>(data);
        try {
          qingqi::hap::ExtractPackageEntry(task->paths[0], task->paths[1], task->paths[2]);
          task->result = 0;
        } catch (const std::exception& error) {
          std::strncpy(task->error.data(), error.what(), task->error.size() - 1);
          task->result = 1;
        }
      },
      [](napi_env env, napi_status status, void* data) {
        auto* task = static_cast<SignWork*>(data);
        if (status == napi_ok && task->result == 0) {
          napi_value value = nullptr;
          napi_get_undefined(env, &value);
          napi_resolve_deferred(env, task->deferred, value);
        } else {
          napi_value message = nullptr;
          napi_value error = nullptr;
          const char* detail = task->error[0] ? task->error.data() : "HAP signing failed";
          napi_create_string_utf8(env, detail, NAPI_AUTO_LENGTH, &message);
          napi_create_error(env, nullptr, message, &error);
          napi_reject_deferred(env, task->deferred, error);
        }
        napi_delete_async_work(env, task->work);
        delete task;
      }, state, &state->work) != napi_ok ||
      napi_queue_async_work(env, state->work) != napi_ok) {
    if (state->work) napi_delete_async_work(env, state->work);
    delete state;
    napi_throw_error(env, nullptr, "Cannot queue signing task");
    return nullptr;
  }
  return promise;
}


struct ArchiveWork { std::string input, output, error, previous_bundle, next_bundle; std::vector<std::pair<std::string,std::string>> files; napi_deferred deferred = nullptr; napi_async_work work = nullptr; };
std::string StringArg(napi_env env, napi_value value) {
  size_t length = 0; if (napi_get_value_string_utf8(env,value,nullptr,0,&length) != napi_ok || !length || length > 4096) throw std::runtime_error("Invalid archive argument");
  std::vector<char> buffer(length + 1); napi_get_value_string_utf8(env,value,buffer.data(),buffer.size(),&length); std::string result(buffer.data(),length);
  if (result.find('\0') != std::string::npos) throw std::runtime_error("Invalid archive argument"); return result;
}
napi_value Rewrite(napi_env env, napi_callback_info info) {
  size_t argc = 6; napi_value args[6]{}; napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
  auto* task = new ArchiveWork();
  try {
    if (argc != 4 && argc != 6) throw std::runtime_error("Expected archive paths, replacement arrays and optional bundle names");
    task->input = StringArg(env,args[0]); task->output = StringArg(env,args[1]);
    if (argc == 6) { task->previous_bundle = StringArg(env,args[4]); task->next_bundle = StringArg(env,args[5]); }
    bool names = false, paths = false; napi_is_array(env,args[2],&names); napi_is_array(env,args[3],&paths);
    uint32_t count = 0, other = 0; napi_get_array_length(env,args[2],&count); napi_get_array_length(env,args[3],&other);
    if (!names || !paths || !count || count > 128 || count != other) throw std::runtime_error("Invalid archive replacements");
    for (uint32_t i=0;i<count;i++) { napi_value name,path; napi_get_element(env,args[2],i,&name); napi_get_element(env,args[3],i,&path); task->files.emplace_back(StringArg(env,name),StringArg(env,path)); }
  } catch (const std::exception& e) { delete task; napi_throw_error(env,"PACKAGE_EDIT",e.what()); return nullptr; }
  napi_value promise = nullptr, name = nullptr;
  if (napi_create_promise(env, &task->deferred, &promise) != napi_ok ||
      napi_create_string_utf8(env, "rewritePackage", NAPI_AUTO_LENGTH, &name) != napi_ok) {
    delete task; napi_throw_error(env, "PACKAGE_EDIT", "Cannot create archive task"); return nullptr;
  }
  if (napi_create_async_work(env,nullptr,name,[](napi_env,void* value) { auto* t=static_cast<ArchiveWork*>(value); try { qingqi::hap::RewriteArchive(t->input,t->output,t->files,t->previous_bundle,t->next_bundle); } catch(const std::exception& e) {t->error=e.what();} },
    [](napi_env env,napi_status status,void* value) { auto* t=static_cast<ArchiveWork*>(value); napi_value result;
      if (status==napi_ok && t->error.empty()) { napi_get_undefined(env,&result); napi_resolve_deferred(env,t->deferred,result); }
      else { napi_value message; napi_create_string_utf8(env,t->error.empty()?"Package edit failed":t->error.c_str(),NAPI_AUTO_LENGTH,&message); napi_create_error(env,nullptr,message,&result); napi_reject_deferred(env,t->deferred,result); }
      napi_delete_async_work(env,t->work); delete t; },task,&task->work)!=napi_ok || napi_queue_async_work(env,task->work)!=napi_ok) {
    if (task->work) napi_delete_async_work(env,task->work); delete task; napi_throw_error(env,"PACKAGE_EDIT","Cannot queue archive edit"); return nullptr;
  }
  return promise;
}

napi_value ListArchiveEntries(napi_env env, napi_callback_info info, bool profiles) {
  size_t argc = 1, length = 0;
  napi_value arg = nullptr;
  napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr);
  if (argc != 1 || napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok || !length || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid archive path"); return nullptr;
  }
  std::vector<char> path(length + 1);
  napi_get_value_string_utf8(env, arg, path.data(), path.size(), &length);
  try {
    const auto entries = profiles ? qingqi::hap::ListProfileEntries(std::string(path.data(), length)) :
      qingqi::hap::ListPackageEntries(std::string(path.data(), length));
    napi_value result = nullptr;
    napi_create_array_with_length(env, entries.size(), &result);
    for (size_t i = 0; i < entries.size(); ++i) {
      napi_value row = nullptr, name = nullptr, size = nullptr;
      napi_create_object(env, &row);
      napi_create_string_utf8(env, entries[i].name.c_str(), entries[i].name.size(), &name);
      napi_create_double(env, static_cast<double>(entries[i].size), &size);
      napi_set_named_property(env, row, "name", name);
      napi_set_named_property(env, row, "size", size);
      napi_set_element(env, result, i, row);
    }
    return result;
  } catch (const std::exception& error) {
    napi_throw_error(env, "PACKAGE_ARCHIVE", error.what()); return nullptr;
  }
}

napi_value ListPackages(napi_env env, napi_callback_info info) { return ListArchiveEntries(env, info, false); }
napi_value ListProfiles(napi_env env, napi_callback_info info) { return ListArchiveEntries(env, info, true); }

napi_value HdcInstallProgress(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  size_t size = 0;
  if (argc < 1 || napi_get_value_string_utf8(env, args[0], nullptr, 0, &size) != napi_ok ||
      size == 0 || size > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid installation path");
    return nullptr;
  }
  std::vector<char> file(size + 1);
  napi_get_value_string_utf8(env, args[0], file.data(), file.size(), &size);
  bool reset = false;
  if (argc > 1) napi_get_value_bool(env, args[1], &reset);
  unsigned char output[256] = {};
  size_t length = 0;
  if (qingqi_hdc_install_progress(file.data(), reset ? 1 : 0, output, sizeof(output), &length) != 0) {
    napi_throw_error(env, nullptr, "Cannot read installation progress");
    return nullptr;
  }
  napi_value value = nullptr;
  napi_create_string_utf8(env, reinterpret_cast<const char*>(output), length, &value);
  return value;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
    {"listProfileEntries", nullptr, ListProfiles, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"listPackageEntries", nullptr, ListPackages, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readArchiveFile", nullptr, ReadArchiveFile, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"rewriteArchive", nullptr, Rewrite, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"extractPackageEntry", nullptr, ExtractPackage, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readModuleJson", nullptr, ReadModule, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readInstallPermissions", nullptr, ReadInstallPermissions, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readPackInfo", nullptr, ReadPack, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"hasSigningBlock", nullptr, HasSigningBlock, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readHapIcon", nullptr, ReadIcon, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"keyMatchesCertificate", nullptr, KeyMatchesCertificate, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"certificateFingerprint", nullptr, CertificateFingerprint, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"readSignedProfile", nullptr, ReadSignedProfile, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"generateCsr", nullptr, GenerateCsr, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"profileMatchesCertificate", nullptr, ProfileMatchesCertificate, nullptr, nullptr,
     nullptr, napi_default, nullptr},
    {"verifyHap", nullptr, VerifyHap, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"signHap", nullptr, SignHap, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"hdcCommand", nullptr, HdcCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"hdcInstallProgress", nullptr, HdcInstallProgress, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"hdcDisconnect", nullptr, HdcDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
  return exports;
}

napi_module module = {
  1, 0, nullptr, Init, "hap_core", nullptr, {0}
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterHapCore() {
  napi_module_register(&module);
}

#include "zip_reader.h"

#include <napi/native_api.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

extern "C" int qingqi_sign_hap(const char* input, const char* output,
                                const char* private_key, const char* certificates,
                                const char* profile, char* error_buffer,
                                size_t error_capacity);
extern "C" int qingqi_key_matches_certificate(const char* private_key,
                                                 const char* certificate);
extern "C" int qingqi_read_signed_profile(const char* profile_path,
                                            unsigned char* output, size_t output_capacity,
                                            size_t* output_length, char* error_buffer,
                                            size_t error_capacity);
extern "C" int qingqi_profile_matches_certificate(const char* profile_path,
                                                     const char* certificate_path);
extern "C" int qingqi_verify_hap(const char* file_path, char* error_buffer,
                                   size_t error_capacity);
extern "C" int qingqi_hdc_disconnect(char* error_buffer, size_t error_capacity);

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
  const int result = profile ?
    qingqi_profile_matches_certificate(paths[0].c_str(), paths[1].c_str()) :
    qingqi_key_matches_certificate(paths[0].c_str(), paths[1].c_str());
  if (result < 0) {
    napi_throw_error(env, "SIGNING_MATERIAL", "Cannot verify key and certificate");
    return nullptr;
  }
  napi_value matched = nullptr;
  napi_get_boolean(env, result == 1, &matched);
  return matched;
}

napi_value KeyMatchesCertificate(napi_env env, napi_callback_info info) {
  return MatchMaterialPair(env, info, false);
}

napi_value ProfileMatchesCertificate(napi_env env, napi_callback_info info) {
  return MatchMaterialPair(env, info, true);
}

napi_value ReadSignedProfile(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value arg = nullptr;
  if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1) {
    napi_throw_type_error(env, nullptr, "Expected a signed profile path");
    return nullptr;
  }
  size_t length = 0;
  if (napi_get_value_string_utf8(env, arg, nullptr, 0, &length) != napi_ok ||
      length == 0 || length > 4096) {
    napi_throw_type_error(env, nullptr, "Invalid signed profile path");
    return nullptr;
  }
  std::vector<char> path(length + 1);
  if (napi_get_value_string_utf8(env, arg, path.data(), path.size(), &length) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid signed profile path");
    return nullptr;
  }
  std::vector<unsigned char> content(256 * 1024);
  size_t content_length = 0;
  std::array<char, 1024> error{};
  if (qingqi_read_signed_profile(path.data(), content.data(), content.size(), &content_length,
                                 error.data(), error.size()) != 0) {
    napi_throw_error(env, "PROFILE_VERIFY", error.data());
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
      state->operation > 5 ||
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

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor properties[] = {
    {"readModuleJson", nullptr, ReadModule, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readPackInfo", nullptr, ReadPack, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"readHapIcon", nullptr, ReadIcon, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"keyMatchesCertificate", nullptr, KeyMatchesCertificate, nullptr, nullptr, nullptr,
     napi_default, nullptr},
    {"readSignedProfile", nullptr, ReadSignedProfile, nullptr, nullptr, nullptr, napi_default,
     nullptr},
    {"profileMatchesCertificate", nullptr, ProfileMatchesCertificate, nullptr, nullptr,
     nullptr, napi_default, nullptr},
    {"verifyHap", nullptr, VerifyHap, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"signHap", nullptr, SignHap, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"hdcCommand", nullptr, HdcCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"hdcDisconnect", nullptr, HdcDisconnect, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  napi_define_properties(env, exports, 10, properties);
  return exports;
}

napi_module module = {
  1, 0, nullptr, Init, "hap_core", nullptr, {0}
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterHapCore() {
  napi_module_register(&module);
}

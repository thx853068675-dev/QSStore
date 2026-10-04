#include "install_archive.h"
#include <archive.h>
#include <archive_entry.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <memory>
#include <set>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/statvfs.h>

namespace qingqi::hap {
namespace {
constexpr uint64_t kLimit = uint64_t{2} * 1024 * 1024 * 1024;
std::string Lower(std::string name) {
  std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
  return name;
}
bool Package(const std::string& name) {
  const auto lower = Lower(name);
  return lower.size() > 4 && (lower.substr(lower.size() - 4) == ".hap" || lower.substr(lower.size() - 4) == ".app");
}
bool SafeName(const std::string& name) {
  if (name.empty() || name.size() > 1024 || name.front() == '/' || name.find('\\') != std::string::npos ||
      name.find(':') != std::string::npos) return false;
  if (std::any_of(name.begin(), name.end(), [](unsigned char c) { return c < 32 || c == 127; })) return false;
  size_t at = 0;
  while (at < name.size()) {
    const auto end = name.find('/', at);
    const auto part = name.substr(at, end == std::string::npos ? end : end - at);
    if (part.empty() || part == "." || part == "..") return false;
    if (end == std::string::npos) break;
    at = end + 1;
  }
  return true;
}
std::string Detail(archive* reader) {
  const char* detail = archive_error_string(reader);
  return detail ? detail : "损坏或不支持的压缩文件";
}
}

std::vector<ImportedArchiveEntry> ExtractInstallArchive(
    const std::string& input, const std::string& output_prefix, const std::string& original_name) {
  struct stat st{};
  if (stat(input.c_str(), &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || uint64_t(st.st_size) > kLimit ||
      output_prefix.empty() || output_prefix == input) throw std::runtime_error("压缩文件大小或输出路径无效");
  std::unique_ptr<archive, decltype(&archive_read_free)> reader(archive_read_new(), archive_read_free);
  if (!reader) throw std::runtime_error("无法创建解压任务");
  // Only built-in readers: never spawn external decompression programs.
  archive_read_support_filter_none(reader.get());
  archive_read_support_filter_gzip(reader.get());
  archive_read_support_filter_bzip2(reader.get());
  archive_read_support_filter_xz(reader.get());
  archive_read_support_filter_lzma(reader.get());
  const auto lower_name = Lower(original_name);
  const auto dot = lower_name.find_last_of('.');
  const auto extension = dot == std::string::npos ? "" : lower_name.substr(dot);
  // A stored HAP is itself ZIP. Unrestricted format bidding can misidentify a
  // RAR containing that HAP as a self-extracting ZIP and expose its inner files.
  if (extension == ".zip") archive_read_support_format_zip(reader.get());
  else if (extension == ".7z") archive_read_support_format_7zip(reader.get());
  else if (extension == ".rar") {
    archive_read_support_format_rar(reader.get());
    archive_read_support_format_rar5(reader.get());
  } else if (dot != std::string::npos && Package(lower_name.substr(0, dot))) {
    archive_read_support_format_raw(reader.get());
  } else archive_read_support_format_tar(reader.get());
  if (archive_read_open_filename(reader.get(), input.c_str(), 64 * 1024) != ARCHIVE_OK)
    throw std::runtime_error("无法读取压缩文件：" + Detail(reader.get()));
  std::vector<ImportedArchiveEntry> result;
  std::vector<std::string> created;
  std::set<std::string> names;
  uint64_t declared_total = 0, written_total = 0;
  size_t count = 0;
  const auto start = std::chrono::steady_clock::now();
  try {
    archive_entry* entry = nullptr;
    int status = 0;
    while ((status = archive_read_next_header(reader.get(), &entry)) != ARCHIVE_EOF) {
      if (status < ARCHIVE_WARN) throw std::runtime_error("压缩文件解析失败：" + Detail(reader.get()));
      if (++count > 10000 || std::chrono::steady_clock::now() - start > std::chrono::minutes(2))
        throw std::runtime_error("压缩文件条目过多或解压超时");
      std::string name = archive_entry_pathname(entry) ? archive_entry_pathname(entry) : "";
      // Standard tar tools commonly prefix relative entry paths with "./".
      while (name.compare(0, 2, "./") == 0) name.erase(0, 2);
      if ((archive_format(reader.get()) & ARCHIVE_FORMAT_BASE_MASK) == ARCHIVE_FORMAT_RAW) {
        name = original_name;
        const auto dot = name.find_last_of('.');
        if (dot != std::string::npos) name.resize(dot);
      }
      const int64_t declared = archive_entry_size_is_set(entry) ? archive_entry_size(entry) : 0;
      if (declared < 0 || uint64_t(declared) > kLimit || declared_total > kLimit - uint64_t(declared))
        throw std::runtime_error("解压后文件超过 2 GB 上限");
      declared_total += uint64_t(declared);
      if (!Package(name)) {
        if (archive_read_data_skip(reader.get()) < ARCHIVE_WARN)
          throw std::runtime_error("无法跳过压缩条目：" + Detail(reader.get()));
        continue;
      }
      if (!SafeName(name) || archive_entry_filetype(entry) != AE_IFREG ||
          archive_entry_symlink(entry) || archive_entry_hardlink(entry) || !names.insert(name).second)
        throw std::runtime_error("压缩包安装条目路径不安全或重复");
      if (archive_entry_is_encrypted(entry)) throw std::runtime_error("请先解密压缩包后再签装");
      if (result.size() >= 32) throw std::runtime_error("压缩包最多支持 32 个安装文件");
      const auto lower = Lower(name);
      const std::string output = output_prefix + "-" + std::to_string(result.size()) + lower.substr(lower.size() - 4);
      struct stat existing{};
      if (!stat(output.c_str(), &existing)) throw std::runtime_error("解压输出已存在，请重新选择文件");
      const auto slash = output.find_last_of('/');
      const std::string parent = slash == std::string::npos ? "." : output.substr(0, slash);
      struct statvfs disk{};
      if (!statvfs(parent.c_str(), &disk) && uint64_t(disk.f_bavail) * disk.f_frsize <
          uint64_t(declared) + 256 * 1024 * 1024) throw std::runtime_error("存储空间不足，请清理后再试");
      created.push_back(output);
      std::ofstream out(output, std::ios::binary | std::ios::trunc);
      if (!out) throw std::runtime_error("无法创建解压文件");
      std::array<char, 64 * 1024> buffer{};
      uint64_t written = 0;
      for (;;) {
        const auto bytes = archive_read_data(reader.get(), buffer.data(), buffer.size());
        if (bytes < 0) throw std::runtime_error("解压失败：" + Detail(reader.get()));
        if (bytes == 0) break;
        written += uint64_t(bytes); written_total += uint64_t(bytes);
        if (written_total > kLimit || written_total / uint64_t(st.st_size) > 200 ||
            (declared && written > uint64_t(declared))) throw std::runtime_error("解压大小异常");
        if (std::chrono::steady_clock::now() - start > std::chrono::minutes(2))
          throw std::runtime_error("解压超时，请拆分压缩包后重试");
        out.write(buffer.data(), bytes);
        if (!out) throw std::runtime_error("解压写入失败，请检查存储空间");
      }
      out.close();
      if (!out || !written || (declared && written != uint64_t(declared)))
        throw std::runtime_error("压缩文件不完整");
      result.push_back({name, output, written});
    }
    if (result.empty()) throw std::runtime_error("压缩包中没有 APP 或 HAP 安装文件");
    return result;
  } catch (...) {
    for (const auto& path : created) std::remove(path.c_str());
    throw;
  }
}
}

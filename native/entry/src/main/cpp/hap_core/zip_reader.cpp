#include "zip_reader.h"
#include "abc_editor.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include <zlib.h>

namespace qingqi::hap {
namespace {

constexpr uint32_t kEocd = 0x06054b50;
constexpr uint32_t kCentral = 0x02014b50;
constexpr uint32_t kLocal = 0x04034b50;
constexpr size_t kMaxManifestSize = 4 * 1024 * 1024;
// App icons are small; anything larger is not an icon and is refused.
constexpr size_t kMaxIconSize = 1024 * 1024;

uint16_t U16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1]) << 8;
}

uint32_t U32(const uint8_t* p) {
  return static_cast<uint32_t>(U16(p)) | static_cast<uint32_t>(U16(p + 2)) << 16;
}

std::vector<uint8_t> Read(std::ifstream& in, uint64_t offset, size_t size,
                          uint64_t file_size) {
  if (offset > file_size || size > file_size - offset ||
      offset > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())) {
    throw std::runtime_error("HAP ZIP entry exceeds file bounds");
  }
  std::vector<uint8_t> bytes(size);
  in.seekg(static_cast<std::streamoff>(offset));
  if (!in || (size > 0 && !in.read(reinterpret_cast<char*>(bytes.data()), size))) {
    throw std::runtime_error("Cannot read HAP ZIP entry");
  }
  return bytes;
}

// Expands one ZIP entry to raw bytes. Icons are binary, so the inflater cannot
// assume text; callers that want JSON convert afterwards.
std::vector<uint8_t> Expand(const std::vector<uint8_t>& compressed, uint32_t expanded_size,
                            uint16_t method, size_t limit) {
  if (expanded_size > limit || compressed.size() > limit) {
    throw std::runtime_error("HAP entry exceeds size limit");
  }
  if (method == 0) {
    if (compressed.size() != expanded_size) {
      throw std::runtime_error("Stored HAP entry has invalid length");
    }
    return compressed;
  }
  if (method != 8) throw std::runtime_error("Unsupported HAP compression");

  std::vector<uint8_t> out(expanded_size);
  z_stream stream{};
  stream.next_in = const_cast<Bytef*>(compressed.data());
  stream.avail_in = static_cast<uInt>(compressed.size());
  stream.next_out = reinterpret_cast<Bytef*>(out.data());
  stream.avail_out = expanded_size;
  if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
    throw std::runtime_error("Cannot initialize HAP inflater");
  }
  const int result = inflate(&stream, Z_FINISH);
  inflateEnd(&stream);
  if (result != Z_STREAM_END || stream.total_out != expanded_size ||
      stream.total_in != compressed.size()) {
    throw std::runtime_error("HAP decompression failed");
  }
  return out;
}

}  // namespace

namespace {

// Splits a module.json icon reference into a file name and its stem.
// `$media:app_icon`, `app_icon.png` and `resources/base/media/app_icon.png`
// must all reduce to the same lookup key. Steps are explicit: substr(npos) has
// surprising semantics, so it is never used inside a ternary here.
void IconNameParts(const std::string& icon_name, std::string& base, std::string& stem) {
  std::string value = icon_name;
  const std::string prefix = "$media:";
  if (value.compare(0, prefix.size(), prefix) == 0) {
    value = value.substr(prefix.size());
  }
  const size_t slash = value.find_last_of('/');
  if (slash != std::string::npos) value = value.substr(slash + 1);
  base = value;
  stem = value;
  const size_t dot = stem.find_last_of('.');
  if (dot != std::string::npos) stem = stem.substr(0, dot);
  // Density-qualified names (`app_icon@3x`) share the unqualified stem.
  const size_t density = stem.find_last_of('@');
  if (density != std::string::npos) stem = stem.substr(0, density);
}

struct CentralEntry {
  std::string name;
  uint16_t flags = 0;
  uint16_t method = 0;
  uint32_t crc = 0;
  uint32_t packed = 0;
  uint32_t unpacked = 0;
  uint32_t local_offset = 0;
};

// Walks the central directory once and validates the footer. Both the metadata
// readers and the icon reader use it, so the ZIP parsing rules stay in one place.
std::vector<CentralEntry> ReadCentralDirectory(std::ifstream& in, uint64_t file_size,
                                               uint64_t& central_offset) {
  if (file_size < 22) throw std::runtime_error("HAP ZIP footer is missing");
  const size_t tail_size = static_cast<size_t>(std::min<uint64_t>(file_size, 22 + 65535));
  const uint64_t tail_start = file_size - tail_size;
  const auto tail = Read(in, tail_start, tail_size, file_size);
  size_t eocd = tail_size;
  for (size_t pos = tail_size - 22;; --pos) {
    if (U32(tail.data() + pos) == kEocd &&
        pos + 22 + U16(tail.data() + pos + 20) == tail_size) {
      eocd = pos;
      break;
    }
    if (pos == 0) break;
  }
  if (eocd == tail_size) throw std::runtime_error("HAP ZIP footer is invalid");
  const uint8_t* footer = tail.data() + eocd;
  const uint16_t count = U16(footer + 10);
  const uint32_t central_size = U32(footer + 12);
  central_offset = U32(footer + 16);
  if (U16(footer + 4) != 0 || U16(footer + 6) != 0 ||
      U16(footer + 8) != count || count == 0 || count == 0xffff ||
      central_size == 0xffffffff || central_offset == 0xffffffff ||
      central_offset + central_size > tail_start + eocd) {
    throw std::runtime_error("Unsupported HAP ZIP directory");
  }

  std::vector<CentralEntry> entries;
  entries.reserve(count);
  uint64_t offset = central_offset;
  const uint64_t directory_end = offset + central_size;
  for (uint32_t i = 0; i < count; ++i) {
    if (offset + 46 > directory_end) throw std::runtime_error("Truncated HAP ZIP directory");
    const auto header = Read(in, offset, 46, file_size);
    if (U32(header.data()) != kCentral) throw std::runtime_error("Invalid HAP ZIP directory");
    const uint16_t name_size = U16(header.data() + 28);
    const uint16_t extra_size = U16(header.data() + 30);
    const uint16_t comment_size = U16(header.data() + 32);
    const uint64_t next = offset + 46 + name_size + extra_size + comment_size;
    if (next > directory_end || name_size == 0) {
      throw std::runtime_error("Invalid HAP ZIP entry length");
    }
    const auto name_bytes = Read(in, offset + 46, name_size, file_size);
    CentralEntry entry;
    entry.name.assign(name_bytes.begin(), name_bytes.end());
    entry.flags = U16(header.data() + 8);
    entry.method = U16(header.data() + 10);
    entry.crc = U32(header.data() + 16);
    entry.packed = U32(header.data() + 20);
    entry.unpacked = U32(header.data() + 24);
    entry.local_offset = U32(header.data() + 42);
    entries.push_back(std::move(entry));
    offset = next;
  }
  return entries;
}

// Extracts one central-directory entry after re-reading its local header.
std::vector<uint8_t> ReadEntry(std::ifstream& in, uint64_t file_size,
                               const CentralEntry& entry, uint64_t central_offset,
                               size_t limit) {
  if (entry.name.empty()) throw std::runtime_error("Invalid HAP ZIP entry length");
  if ((entry.flags & 1) != 0 || entry.packed == 0 || entry.unpacked == 0 ||
      entry.packed > limit || entry.unpacked > limit ||
      entry.local_offset == 0xffffffff) {
    throw std::runtime_error("Unsupported HAP entry");
  }
  const auto local = Read(in, entry.local_offset, 30, file_size);
  const uint16_t name_size = U16(local.data() + 26);
  if (U32(local.data()) != kLocal || U16(local.data() + 8) != entry.method ||
      name_size != entry.name.size()) {
    throw std::runtime_error("HAP headers disagree");
  }
  const auto name_bytes = Read(in, static_cast<uint64_t>(entry.local_offset) + 30,
                               name_size, file_size);
  if (std::string(name_bytes.begin(), name_bytes.end()) != entry.name) {
    throw std::runtime_error("HAP entry names disagree");
  }
  const uint64_t data_offset = static_cast<uint64_t>(entry.local_offset) + 30 +
    name_size + U16(local.data() + 28);
  if (data_offset + entry.packed > central_offset) {
    throw std::runtime_error("HAP entry overlaps ZIP directory");
  }
  const auto data = Read(in, data_offset, entry.packed, file_size);
  auto expanded = Expand(data, entry.unpacked, entry.method, limit);
  if (crc32(0, reinterpret_cast<const Bytef*>(expanded.data()), expanded.size()) != entry.crc) {
    throw std::runtime_error("HAP entry checksum mismatch");
  }
  return expanded;
}

std::ifstream OpenHap(const std::string& hap_path, uint64_t& file_size) {
  std::ifstream in(hap_path, std::ios::binary | std::ios::ate);
  if (!in) throw std::runtime_error("Cannot open HAP");
  const auto end = in.tellg();
  if (end < 22) throw std::runtime_error("HAP ZIP footer is missing");
  file_size = static_cast<uint64_t>(end);
  return in;
}

}  // namespace

namespace {
constexpr uint64_t kPackageLimit = 2ULL * 1024 * 1024 * 1024;
bool PackageName(const std::string& name) {
  if (name.empty() || name.size() > 1024 || name.front() == '/' ||
      name.find('\\') != std::string::npos || name.find('\0') != std::string::npos ||
      name.find(':') != std::string::npos) return false;
  size_t pos = 0;
  while (pos < name.size()) {
    const auto end = name.find('/', pos);
    const auto part = name.substr(pos, end == std::string::npos ? end : end - pos);
    if (part.empty() || part == "." || part == "..") return false;
    if (end == std::string::npos) break;
    pos = end + 1;
  }
  auto lower = name;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
  return lower.size() >= 4 && (lower.compare(lower.size() - 4, 4, ".hap") == 0 ||
                               lower.compare(lower.size() - 4, 4, ".app") == 0);
}
}

std::vector<ArchiveEntry> ListPackageEntries(const std::string& archive_path) {
  uint64_t size = 0, central = 0;
  auto in = OpenHap(archive_path, size);
  if (size > kPackageLimit) throw std::runtime_error("Archive exceeds 2 GB limit");
  const auto entries = ReadCentralDirectory(in, size, central);
  std::vector<ArchiveEntry> result;
  uint64_t total = 0;
  for (const auto& entry : entries) {
    if (!PackageName(entry.name)) continue;
    if ((entry.flags & 1) || (entry.method != 0 && entry.method != 8) ||
        !entry.unpacked || entry.unpacked > kPackageLimit || !entry.packed ||
        entry.unpacked / entry.packed > 200) throw std::runtime_error("Unsafe package archive entry");
    if (std::any_of(result.begin(), result.end(), [&](const auto& row) { return row.name == entry.name; }))
      throw std::runtime_error("Duplicate package archive entry");
    total += entry.unpacked;
    if (result.size() >= 32 || total > kPackageLimit) throw std::runtime_error("Too many or oversized packages in archive");
    result.push_back({entry.name, entry.unpacked});
  }
  return result;
}

std::vector<ArchiveEntry> ListProfileEntries(const std::string& archive_path) {
  uint64_t size = 0, central = 0;
  auto in = OpenHap(archive_path, size);
  if (size > kPackageLimit) throw std::runtime_error("Archive exceeds 2 GB limit");
  const auto entries = ReadCentralDirectory(in, size, central);
  std::vector<ArchiveEntry> result;
  uint64_t total = 0;
  for (const auto& entry : entries) {
    if (entry.name.compare(0, 10, "resources/") || entry.name.find("/profile/") == std::string::npos ||
        entry.name.size() < 5 || entry.name.compare(entry.name.size() - 5, 5, ".json")) continue;
    if (entry.name.find("..") != std::string::npos || entry.name.find('\\') != std::string::npos ||
        entry.name.find('\0') != std::string::npos || (entry.flags & 1) ||
        (entry.method != 0 && entry.method != 8) || entry.unpacked > kMaxManifestSize)
      throw std::runtime_error("Unsafe profile entry");
    if (std::any_of(result.begin(), result.end(), [&](const auto& row) { return row.name == entry.name; }))
      throw std::runtime_error("Duplicate profile entry");
    total += entry.unpacked;
    if (result.size() >= 256 || total > 16 * 1024 * 1024) throw std::runtime_error("Too many or oversized profiles");
    result.push_back({entry.name, entry.unpacked});
  }
  return result;
}

void ExtractPackageEntry(const std::string& archive_path, const std::string& name,
                         const std::string& output) {
  const auto allowed = ListPackageEntries(archive_path);
  if (output == archive_path || std::none_of(allowed.begin(), allowed.end(),
      [&](const auto& entry) { return entry.name == name; })) throw std::runtime_error("Invalid archive package selection");
  uint64_t size = 0, central = 0;
  auto in = OpenHap(archive_path, size);
  const auto entries = ReadCentralDirectory(in, size, central);
  const auto entry = *std::find_if(entries.begin(), entries.end(), [&](const auto& row) { return row.name == name; });
  const auto local = Read(in, entry.local_offset, 30, size);
  const auto name_size = U16(local.data() + 26);
  const auto actual = Read(in, static_cast<uint64_t>(entry.local_offset) + 30, name_size, size);
  const uint64_t offset = static_cast<uint64_t>(entry.local_offset) + 30 + name_size + U16(local.data() + 28);
  if (U32(local.data()) != kLocal || U16(local.data() + 8) != entry.method ||
      (U16(local.data() + 6) & 1) || std::string(actual.begin(), actual.end()) != name ||
      offset + entry.packed > central) throw std::runtime_error("Archive package headers disagree");
  std::ofstream out(output, std::ios::binary | std::ios::trunc);
  if (!out) throw std::runtime_error("Cannot create extracted package");
  z_stream stream{};
  if (entry.method == 8 && inflateInit2(&stream, -MAX_WBITS) != Z_OK)
    throw std::runtime_error("Cannot initialize package inflater");
  std::array<uint8_t, 64 * 1024> packed{}, expanded{};
  uint64_t consumed = 0, produced = 0;
  uLong crc = crc32(0, Z_NULL, 0);
  int state = Z_OK;
  try {
    in.seekg(static_cast<std::streamoff>(offset));
    while (consumed < entry.packed) {
      const size_t chunk = std::min<uint64_t>(packed.size(), entry.packed - consumed);
      if (!in.read(reinterpret_cast<char*>(packed.data()), chunk)) throw std::runtime_error("Truncated package entry");
      consumed += chunk;
      stream.next_in = packed.data(); stream.avail_in = chunk;
      do {
        size_t count = chunk;
        const uint8_t* bytes = packed.data();
        if (entry.method == 8) {
          stream.next_out = expanded.data(); stream.avail_out = expanded.size();
          state = inflate(&stream, Z_NO_FLUSH);
          // A full output buffer can consume the last input byte. The next
          // flush then legitimately reports Z_BUF_ERROR: refill the input,
          // rather than treating this chunk boundary as a corrupted package.
          if (state == Z_BUF_ERROR && stream.avail_in == 0 && stream.avail_out == expanded.size()) break;
          if (state != Z_OK && state != Z_STREAM_END)
            throw std::runtime_error("Package decompression failed (zlib " + std::to_string(state) + ")");
          count = expanded.size() - stream.avail_out; bytes = expanded.data();
        } else stream.avail_in = 0;
        produced += count;
        if (produced > entry.unpacked) throw std::runtime_error("Package expansion exceeds declared size");
        out.write(reinterpret_cast<const char*>(bytes), count);
        if (!out) throw std::runtime_error("Cannot write extracted package");
        crc = crc32(crc, bytes, count);
        if (state == Z_STREAM_END && (stream.avail_in || consumed != entry.packed))
          throw std::runtime_error("Package entry has trailing compressed data");
      } while (stream.avail_in || (entry.method == 8 && state != Z_STREAM_END && !stream.avail_out));
    }
    if (produced != entry.unpacked || crc != entry.crc || (entry.method == 8 && state != Z_STREAM_END))
      throw std::runtime_error("Extracted package checksum or length mismatch");
  } catch (...) {
    if (entry.method == 8) inflateEnd(&stream);
    out.close(); std::remove(output.c_str()); throw;
  }
  if (entry.method == 8) inflateEnd(&stream);
}

std::vector<uint8_t> ReadEntryBytes(const std::string& hap_path,
                                    const std::string& entry_name, size_t limit) {
  uint64_t file_size = 0;
  auto in = OpenHap(hap_path, file_size);
  uint64_t central_offset = 0;
  const auto entries = ReadCentralDirectory(in, file_size, central_offset);
  std::optional<std::vector<uint8_t>> found;
  for (const auto& entry : entries) {
    if (entry.name != entry_name) continue;
    if (found.has_value()) throw std::runtime_error("Duplicate HAP entry");
    found = ReadEntry(in, file_size, entry, central_offset, limit);
  }
  if (!found.has_value()) throw std::runtime_error("HAP entry is missing: " + entry_name);
  return *found;
}

std::string ReadMetadata(const std::string& hap_path, const std::string& entry_name,
                         bool required) {
  try {
    const auto bytes = ReadEntryBytes(hap_path, entry_name, kMaxManifestSize);
    return std::string(bytes.begin(), bytes.end());
  } catch (const std::exception& error) {
    // pack.info is genuinely absent on older HAPs; that is not an error.
    if (!required && std::string(error.what()).find("is missing") != std::string::npos) {
      return "";
    }
    throw;
  }
}

std::string ReadModuleJson(const std::string& hap_path) {
  return ReadMetadata(hap_path, "module.json", true);
}

std::string ReadPackInfo(const std::string& hap_path) {
  return ReadMetadata(hap_path, "pack.info", false);
}

std::vector<uint8_t> ReadHapIcon(const std::string& hap_path, const std::string& icon_name) {
  // The name comes from module.json and is used as a lookup key, never as a path.
  std::string base;
  std::string stem;
  IconNameParts(icon_name, base, stem);
  if (base.empty()) return {};

  uint64_t file_size = 0;
  auto in = OpenHap(hap_path, file_size);
  uint64_t central_offset = 0;
  const auto entries = ReadCentralDirectory(in, file_size, central_offset);

  // Prefer the exact requested path, then any media entry with the same stem.
  std::vector<std::string> candidates;
  candidates.push_back("resources/base/media/" + base);
  for (const auto& entry : entries) {
    const std::string& name = entry.name;
    if (name.compare(0, 10, "resources/") != 0) continue;
    if (name.find("/media/") == std::string::npos) continue;
    std::string leaf;
    std::string leaf_stem;
    IconNameParts(name, leaf, leaf_stem);
    if (leaf == base || leaf_stem == stem) candidates.push_back(name);
  }

  for (const auto& candidate : candidates) {
    for (const auto& entry : entries) {
      if (entry.name != candidate) continue;
      try {
        return ReadEntry(in, file_size, entry, central_offset, kMaxIconSize);
      } catch (const std::exception&) {
        // A single unreadable candidate must not abort the lookup.
      }
    }
  }
  return {};
}


namespace {
void Put16(std::ostream& out, uint16_t value) { char bytes[2] = {char(value), char(value >> 8)}; out.write(bytes, 2); }
void Put32(std::ostream& out, uint32_t value) { Put16(out, uint16_t(value)); Put16(out, uint16_t(value >> 16)); }
bool SafeZipName(const std::string& name) {
  if (name.empty() || name.size() > 1024 || name.front() == '/' || name.find('\\') != std::string::npos || name.find('\0') != std::string::npos || name.find(':') != std::string::npos) return false;
  size_t at = 0;
  while (at < name.size()) { auto end = name.find('/', at); auto part = name.substr(at, end == std::string::npos ? end : end - at); if (part.empty() || part == "." || part == "..") return false; if (end == std::string::npos) break; at = end + 1; }
  return true;
}
}
void RewriteArchive(const std::string& input, const std::string& output,
                    const std::vector<std::pair<std::string, std::string>>& replacements,
                    const std::string& previous_bundle, const std::string& next_bundle) {
  if (input == output || replacements.empty() || replacements.size() > 128) throw std::runtime_error("Invalid archive edit");
  if (previous_bundle.empty() != next_bundle.empty() || previous_bundle.size() > 128 || next_bundle.size() > 128)
    throw std::runtime_error("Invalid bundle rename");
  uint64_t size = 0, central = 0; auto in = OpenHap(input, size);
  if (size > kPackageLimit) throw std::runtime_error("Package exceeds 2 GB");
  auto entries = ReadCentralDirectory(in, size, central);
  std::vector<std::string> names;
  for (const auto& entry : entries) {
    if (!SafeZipName(entry.name) || (entry.flags & 1) || (entry.method != 0 && entry.method != 8) ||
        std::find(names.begin(), names.end(), entry.name) != names.end()) throw std::runtime_error("Unsafe or duplicate archive entry");
    names.push_back(entry.name);
  }
  for (const auto& replacement : replacements) {
    if (!SafeZipName(replacement.first) || replacement.second == input || replacement.second == output) throw std::runtime_error("Invalid replacement");
    if (std::count_if(replacements.begin(), replacements.end(), [&](const auto& row) {return row.first == replacement.first;}) != 1) throw std::runtime_error("Duplicate replacement");
    if (std::find(names.begin(), names.end(), replacement.first) == names.end()) { CentralEntry item; item.name = replacement.first; entries.push_back(item); }
  }
  if (entries.size() >= 65535) throw std::runtime_error("Too many archive entries");
  std::ofstream out(output, std::ios::binary | std::ios::trunc); if (!out) throw std::runtime_error("Cannot create edited package");
  std::array<char, 256 * 1024> buffer{};
  uint64_t bytecode_total = 0;
  size_t bytecode_count = 0;
  try {
    for (auto& entry : entries) {
      const auto replacement = std::find_if(replacements.begin(), replacements.end(), [&](const auto& row) {return row.first == entry.name;});
      std::vector<uint8_t> bytecode;
      const bool rename_abc = !previous_bundle.empty() && previous_bundle != next_bundle &&
        entry.name.size() > 4 && entry.name.substr(entry.name.size() - 4) == ".abc";
      if (rename_abc) {
        bytecode_total += entry.unpacked;
        if (++bytecode_count > 32 || bytecode_total > 256 * 1024 * 1024)
          throw std::runtime_error("待编辑的字节码总量过大");
        if (replacement != replacements.end()) throw std::runtime_error("Cannot replace and rename the same bytecode");
        bytecode = AbcBundleEditor(ReadEntry(in, size, entry, central, 64 * 1024 * 1024)).Rename(previous_bundle, next_bundle);
      }
      uint64_t source_offset = 0; std::ifstream changed;
      if (rename_abc) {
        entry.packed = entry.unpacked = bytecode.size(); entry.method = 0;
        entry.crc = crc32(0, bytecode.data(), bytecode.size());
      } else if (replacement != replacements.end()) {
        changed.open(replacement->second, std::ios::binary | std::ios::ate); auto length = changed.tellg();
        if (!changed || length < 0 || uint64_t(length) > kPackageLimit) throw std::runtime_error("Invalid replacement file");
        entry.packed = entry.unpacked = uint32_t(length); entry.method = 0; entry.crc = 0; changed.seekg(0);
        while (changed) { changed.read(buffer.data(), buffer.size()); auto count = changed.gcount(); if (count > 0) entry.crc = crc32(entry.crc, reinterpret_cast<Bytef*>(buffer.data()), count); }
        if (!changed.eof()) {
          throw std::runtime_error("Cannot read replacement");
        }
        changed.clear();
        changed.seekg(0);
      } else {
        const auto local = Read(in, entry.local_offset, 30, size); auto name_size = U16(local.data() + 26);
        if (U32(local.data()) != kLocal || U16(local.data() + 8) != entry.method || name_size != entry.name.size()) throw std::runtime_error("Archive headers disagree");
        const auto local_name = Read(in, uint64_t(entry.local_offset) + 30, name_size, size);
        if (std::string(local_name.begin(), local_name.end()) != entry.name) throw std::runtime_error("Archive names disagree");
        source_offset = uint64_t(entry.local_offset) + 30 + name_size + U16(local.data() + 28);
        if (source_offset + entry.packed > central) throw std::runtime_error("Archive payload out of bounds");
      }
      const auto offset = uint64_t(out.tellp()); if (offset + entry.packed + 65536 > kPackageLimit) throw std::runtime_error("Edited package exceeds 2 GB");
      entry.local_offset = uint32_t(offset); entry.flags &= uint16_t(~8U);
      uint16_t padding = 0;
      if (entry.method == 0 && entry.name.size() >= 3 && entry.name.substr(entry.name.size() - 3) == ".so") {
        padding = uint16_t((16384 - ((offset + 30 + entry.name.size()) % 16384)) % 16384);
        if (padding && padding < 4) padding += 16384;
      }
      Put32(out, kLocal); Put16(out, 20); Put16(out, entry.flags); Put16(out, entry.method); Put32(out, 0);
      Put32(out, entry.crc); Put32(out, entry.packed); Put32(out, entry.unpacked); Put16(out, entry.name.size()); Put16(out, padding); out.write(entry.name.data(), entry.name.size());
      if (padding) { Put16(out, 0xffff); Put16(out, padding - 4); std::vector<char> zero(padding - 4); out.write(zero.data(), zero.size()); }
      uint64_t left = entry.packed; auto& source = replacement != replacements.end() ? changed : in;
      if (rename_abc) out.write(reinterpret_cast<const char*>(bytecode.data()), bytecode.size());
      else {
        if (replacement == replacements.end()) { source.clear(); source.seekg(source_offset); }
        while (left) { auto count = std::min<uint64_t>(left, buffer.size()); if (!source.read(buffer.data(), count)) throw std::runtime_error("Truncated archive payload"); out.write(buffer.data(), count); left -= count; }
      }
      if (!out) throw std::runtime_error("Cannot write edited package");
    }
    const auto directory = uint64_t(out.tellp());
    for (const auto& entry : entries) {
      Put32(out, kCentral); Put16(out, 20); Put16(out, 20); Put16(out, entry.flags); Put16(out, entry.method); Put32(out, 0);
      Put32(out, entry.crc); Put32(out, entry.packed); Put32(out, entry.unpacked); Put16(out, entry.name.size()); Put16(out, 0); Put16(out, 0); Put16(out, 0); Put16(out, 0); Put32(out, 0); Put32(out, entry.local_offset); out.write(entry.name.data(), entry.name.size());
    }
    const auto end = uint64_t(out.tellp()); Put32(out, kEocd); Put16(out, 0); Put16(out, 0); Put16(out, entries.size()); Put16(out, entries.size()); Put32(out, end - directory); Put32(out, directory); Put16(out, 0);
    out.flush(); if (!out) throw std::runtime_error("Cannot finish edited package");
  } catch (...) { out.close(); std::remove(output.c_str()); throw; }
}

}  // namespace qingqi::hap

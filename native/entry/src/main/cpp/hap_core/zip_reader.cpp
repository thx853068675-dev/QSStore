#include "zip_reader.h"

#include <algorithm>
#include <array>
#include <cstdint>
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
constexpr size_t kMaxCompressedSize = 4 * 1024 * 1024;

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

std::string Decode(const std::vector<uint8_t>& compressed, uint32_t expanded_size,
                   uint16_t method) {
  if (expanded_size > kMaxManifestSize || compressed.size() > kMaxCompressedSize) {
    throw std::runtime_error("HAP manifest exceeds size limit");
  }
  if (method == 0) {
    if (compressed.size() != expanded_size) {
      throw std::runtime_error("Stored HAP manifest has invalid length");
    }
    return std::string(compressed.begin(), compressed.end());
  }
  if (method != 8) throw std::runtime_error("Unsupported HAP manifest compression");

  std::string out(expanded_size, '\0');
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
    throw std::runtime_error("HAP manifest decompression failed");
  }
  return out;
}

}  // namespace

std::string ReadMetadata(const std::string& hap_path, const std::string& entry_name,
                         bool required) {
  std::ifstream in(hap_path, std::ios::binary | std::ios::ate);
  if (!in) throw std::runtime_error("Cannot open HAP");
  const auto end = in.tellg();
  if (end < 22) throw std::runtime_error("HAP ZIP footer is missing");
  const uint64_t file_size = static_cast<uint64_t>(end);
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
  const uint32_t central_offset = U32(footer + 16);
  if (U16(footer + 4) != 0 || U16(footer + 6) != 0 ||
      U16(footer + 8) != count || count == 0 || count == 0xffff ||
      central_size == 0xffffffff || central_offset == 0xffffffff ||
      static_cast<uint64_t>(central_offset) + central_size > tail_start + eocd) {
    throw std::runtime_error("Unsupported HAP ZIP directory");
  }

  uint64_t offset = central_offset;
  const uint64_t directory_end = offset + central_size;
  std::optional<std::string> manifest;
  for (uint32_t i = 0; i < count; ++i) {
    if (offset + 46 > directory_end) throw std::runtime_error("Truncated HAP ZIP directory");
    const auto header = Read(in, offset, 46, file_size);
    if (U32(header.data()) != kCentral) throw std::runtime_error("Invalid HAP ZIP directory");
    const uint16_t flags = U16(header.data() + 8);
    const uint16_t method = U16(header.data() + 10);
    const uint32_t crc = U32(header.data() + 16);
    const uint32_t packed = U32(header.data() + 20);
    const uint32_t unpacked = U32(header.data() + 24);
    const uint16_t name_size = U16(header.data() + 28);
    const uint16_t extra_size = U16(header.data() + 30);
    const uint16_t comment_size = U16(header.data() + 32);
    const uint32_t local_offset = U32(header.data() + 42);
    const uint64_t next = offset + 46 + name_size + extra_size + comment_size;
    if (next > directory_end || name_size == 0) {
      throw std::runtime_error("Invalid HAP ZIP entry length");
    }
    const auto name_bytes = Read(in, offset + 46, name_size, file_size);
    const std::string name(name_bytes.begin(), name_bytes.end());
    offset = next;
    if (name != entry_name) continue;
    if (manifest.has_value()) throw std::runtime_error("Duplicate HAP metadata entry");
    if ((flags & 1) != 0 || packed == 0 || unpacked == 0 || packed > kMaxCompressedSize ||
        unpacked > kMaxManifestSize || local_offset == 0xffffffff) {
      throw std::runtime_error("Unsupported HAP manifest entry");
    }
    const auto local = Read(in, local_offset, 30, file_size);
    if (U32(local.data()) != kLocal || U16(local.data() + 8) != method) {
      throw std::runtime_error("HAP manifest headers disagree");
    }
    if (U16(local.data() + 26) != name_size ||
        Read(in, static_cast<uint64_t>(local_offset) + 30, name_size, file_size) != name_bytes) {
      throw std::runtime_error("HAP manifest names disagree");
    }
    const uint64_t data_offset = static_cast<uint64_t>(local_offset) + 30 +
      U16(local.data() + 26) + U16(local.data() + 28);
    if (data_offset + packed > central_offset) {
      throw std::runtime_error("HAP manifest overlaps ZIP directory");
    }
    const auto data = Read(in, data_offset, packed, file_size);
    const std::string json = Decode(data, unpacked, method);
    if (crc32(0, reinterpret_cast<const Bytef*>(json.data()), json.size()) != crc) {
      throw std::runtime_error("HAP manifest checksum mismatch");
    }
    manifest = json;
  }
  if (!manifest.has_value()) {
    if (required) throw std::runtime_error("HAP metadata entry is missing");
    return "";
  }
  return *manifest;
}

std::string ReadModuleJson(const std::string& hap_path) {
  return ReadMetadata(hap_path, "module.json", true);
}

std::string ReadPackInfo(const std::string& hap_path) {
  return ReadMetadata(hap_path, "pack.info", false);
}

}  // namespace qingqi::hap

#include "signing_block.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <vector>

namespace qingqi::hap {
namespace {

constexpr uint32_t kEocd = 0x06054b50;
constexpr uint32_t kSignatureScheme = 0x20000000;
constexpr uint64_t kMagicV2Lo = 0x2067695320504148;
constexpr uint64_t kMagicV2Hi = 0x3234206b636f6c42;
constexpr uint64_t kMagicV3Lo = 0x676973207061683c;
constexpr uint64_t kMagicV3Hi = 0x3e6b636f6c62206e;
constexpr uint64_t kMaxBlockSize = 1024ULL * 1024 * 1024;
constexpr uint32_t kMaxBlockCount = 10;

uint16_t U16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1]) << 8;
}

uint32_t U32(const uint8_t* p) {
  return static_cast<uint32_t>(U16(p)) | static_cast<uint32_t>(U16(p + 2)) << 16;
}

uint64_t U64(const uint8_t* p) {
  return static_cast<uint64_t>(U32(p)) | static_cast<uint64_t>(U32(p + 4)) << 32;
}

std::vector<uint8_t> Read(std::ifstream& in, uint64_t offset, size_t size,
                          uint64_t file_size) {
  if (offset > file_size || size > file_size - offset ||
      offset > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())) {
    throw std::runtime_error("HAP signing block exceeds file bounds");
  }
  std::vector<uint8_t> bytes(size);
  in.seekg(static_cast<std::streamoff>(offset));
  if (!in || (size > 0 && !in.read(reinterpret_cast<char*>(bytes.data()), size))) {
    throw std::runtime_error("Cannot read HAP signing block");
  }
  return bytes;
}

}  // namespace

SigningBlockInfo InspectSigningBlock(const std::string& hap_path) {
  std::ifstream in(hap_path, std::ios::binary | std::ios::ate);
  if (!in) throw std::runtime_error("Cannot open HAP");
  const auto end = in.tellg();
  if (end < 54) throw std::runtime_error("HAP signing block is missing");
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
  const uint64_t eocd_offset = tail_start + eocd;
  const uint32_t central_size = U32(footer + 12);
  const uint32_t central_offset = U32(footer + 16);
  if (U16(footer + 4) != 0 || U16(footer + 6) != 0 ||
      U16(footer + 8) != U16(footer + 10) ||
      U16(footer + 10) == 0xffff || central_size == 0xffffffff ||
      central_offset == 0xffffffff ||
      static_cast<uint64_t>(central_offset) + central_size != eocd_offset ||
      central_offset < 32) {
    throw std::runtime_error("Unsupported HAP ZIP directory");
  }

  const auto trailer = Read(in, central_offset - 32, 32, file_size);
  const uint32_t block_count = U32(trailer.data());
  const uint64_t block_size = U64(trailer.data() + 4);
  const uint64_t magic_lo = U64(trailer.data() + 12);
  const uint64_t magic_hi = U64(trailer.data() + 20);
  const uint32_t version = U32(trailer.data() + 28);
  const bool valid_magic = (version == 2 && magic_lo == kMagicV2Lo && magic_hi == kMagicV2Hi) ||
    (version == 3 && magic_lo == kMagicV3Lo && magic_hi == kMagicV3Hi);
  if (!valid_magic || block_count == 0 || block_count > kMaxBlockCount ||
      block_size > kMaxBlockSize || block_size > central_offset ||
      block_size < 32 + static_cast<uint64_t>(block_count) * 12) {
    throw std::runtime_error("HAP signing block header is invalid");
  }

  const uint64_t block_offset = central_offset - block_size;
  const uint64_t data_end = block_size - 32;
  const auto headers = Read(in, block_offset, block_count * 12, file_size);
  uint64_t expected_offset = static_cast<uint64_t>(block_count) * 12;
  bool found_signature = false;
  for (uint32_t i = 0; i < block_count; ++i) {
    const uint8_t* header = headers.data() + i * 12;
    const uint32_t type = U32(header);
    const uint32_t length = U32(header + 4);
    const uint32_t offset = U32(header + 8);
    if (length == 0 || offset != expected_offset || length > data_end - expected_offset) {
      throw std::runtime_error("HAP signing subblock is invalid");
    }
    if (type == kSignatureScheme) {
      if (found_signature) throw std::runtime_error("Duplicate HAP signature scheme");
      found_signature = true;
    }
    expected_offset += length;
  }
  if (!found_signature || expected_offset != data_end) {
    throw std::runtime_error("HAP signature scheme is missing or block length disagrees");
  }
  return SigningBlockInfo{version, block_count, block_offset, block_size};
}

}  // namespace qingqi::hap

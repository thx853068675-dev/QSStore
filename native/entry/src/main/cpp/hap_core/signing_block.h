#pragma once

#include <cstdint>
#include <string>

namespace qingqi::hap {

// Structural inspection only. A well-formed block is not proof of a valid
// signature; cryptographic verification must be completed separately.
struct SigningBlockInfo {
  uint32_t version = 0;
  uint32_t block_count = 0;
  uint64_t offset = 0;
  uint64_t size = 0;
};

SigningBlockInfo InspectSigningBlock(const std::string& hap_path);

}  // namespace qingqi::hap

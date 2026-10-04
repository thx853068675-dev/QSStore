#pragma once
#include <cstdint>
#include <string>
#include <vector>
namespace qingqi::hap {
struct ImportedArchiveEntry { std::string name, path; uint64_t size; };
std::vector<ImportedArchiveEntry> ExtractInstallArchive(
  const std::string& input, const std::string& output_prefix, const std::string& original_name);
}

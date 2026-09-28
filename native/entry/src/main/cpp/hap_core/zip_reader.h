#pragma once

#include <string>

namespace qingqi::hap {

// Reads only the manifest entry. It never extracts arbitrary ZIP paths and
// caps both compressed and expanded metadata before allocation.
std::string ReadModuleJson(const std::string& hap_path);
// Optional for older HAPs. Present but malformed entries still fail closed.
std::string ReadPackInfo(const std::string& hap_path);

}  // namespace qingqi::hap

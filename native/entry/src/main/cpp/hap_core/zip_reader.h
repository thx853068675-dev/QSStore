#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace qingqi::hap {

struct ArchiveEntry { std::string name; uint64_t size; };
std::vector<ArchiveEntry> ListPackageEntries(const std::string& archive_path);
// Streams to a caller-chosen sandbox path; archive names never become paths.
void ExtractPackageEntry(const std::string& archive_path, const std::string& name,
                         const std::string& output);

// Reads only the manifest entry. It never extracts arbitrary ZIP paths and
// caps both compressed and expanded metadata before allocation.
std::string ReadModuleJson(const std::string& hap_path);
// Optional for older HAPs. Present but malformed entries still fail closed.
std::string ReadPackInfo(const std::string& hap_path);

// Reads one named entry as raw bytes. Used for binary payloads such as the app
// icon, where a std::string would be a poor container for the data.
std::vector<uint8_t> ReadEntryBytes(const std::string& hap_path,
                                    const std::string& entry_name, size_t limit);

// Resolves the app icon inside a local HAP and returns its encoded bytes.
// `icon_name` is the module.json value (for example `$media:app_icon`) and is
// only ever used as a lookup key. Returns an empty vector when the HAP has no
// readable icon; callers treat that as "no icon available", never as an error.
std::vector<uint8_t> ReadHapIcon(const std::string& hap_path, const std::string& icon_name);

}  // namespace qingqi::hap

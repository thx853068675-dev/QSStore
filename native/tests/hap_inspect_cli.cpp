#include "zip_reader.h"
#include "signing_block.h"

#include <cstdint>
#include <exception>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  try {
    if (argc >= 8 && std::string(argv[2]) == "rename" && argc % 2 == 0) {
      std::vector<std::pair<std::string, std::string>> replacements;
      for (int i = 6; i < argc; i += 2) replacements.emplace_back(argv[i], argv[i + 1]);
      qingqi::hap::RewriteArchive(argv[1], argv[3], replacements, argv[4], argv[5]);
    } else if (argc >= 6 && std::string(argv[2]) == "rewrite" && argc % 2 == 0) {
      std::vector<std::pair<std::string, std::string>> replacements;
      for (int i = 4; i < argc; i += 2) replacements.emplace_back(argv[i], argv[i + 1]);
      qingqi::hap::RewriteArchive(argv[1], argv[3], replacements);
    } else if (argc == 4 && std::string(argv[2]) == "read") {
      const auto bytes = qingqi::hap::ReadEntryBytes(argv[1], argv[3], 4 * 1024 * 1024);
      std::cout.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    } else if (argc == 5 && std::string(argv[2]) == "extract") {
      qingqi::hap::ExtractPackageEntry(argv[1], argv[3], argv[4]);
    } else if (argc == 3 && (std::string(argv[2]) == "list" || std::string(argv[2]) == "profiles")) {
      for (const auto& entry : (std::string(argv[2]) == "profiles" ? qingqi::hap::ListProfileEntries(argv[1]) : qingqi::hap::ListPackageEntries(argv[1])))
        std::cout << entry.size << '\t' << entry.name << '\n';
    } else if (argc == 4 && std::string(argv[2]) == "icon") {
      // Writes the raw icon bytes so tests can check the real payload.
      const std::vector<uint8_t> icon = qingqi::hap::ReadHapIcon(argv[1], argv[3]);
      std::cout.write(reinterpret_cast<const char*>(icon.data()),
                      static_cast<std::streamsize>(icon.size()));
    } else if (argc == 3 && std::string(argv[2]) == "block") {
      const auto block = qingqi::hap::InspectSigningBlock(argv[1]);
      std::cout << block.version << ',' << block.block_count << ',' <<
        block.offset << ',' << block.size;
    } else {
      std::cout << (argc == 3 && std::string(argv[2]) == "pack" ?
        qingqi::hap::ReadPackInfo(argv[1]) : qingqi::hap::ReadModuleJson(argv[1]));
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}

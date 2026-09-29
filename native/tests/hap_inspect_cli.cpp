#include "zip_reader.h"
#include "signing_block.h"

#include <cstdint>
#include <exception>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 2 && argc != 3 && argc != 4) return 2;
  try {
    if (argc == 4 && std::string(argv[2]) == "icon") {
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

#include "zip_reader.h"
#include "signing_block.h"

#include <exception>
#include <iostream>

int main(int argc, char** argv) {
  if (argc != 2 && argc != 3) return 2;
  try {
    if (argc == 3 && std::string(argv[2]) == "block") {
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

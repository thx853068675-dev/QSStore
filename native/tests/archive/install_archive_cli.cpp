#include "install_archive.h"
#include <archive.h>
#include <archive_entry.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
int main(int argc, char** argv) {
  try {
    if (argc != 5) throw std::runtime_error("Usage: extract archive prefix original | 7z output input name");
    if (std::string(argv[1]) == "extract") {
      for (const auto& entry : qingqi::hap::ExtractInstallArchive(argv[2], argv[3], argv[4]))
        std::cout << entry.name << '\t' << entry.path << '\t' << entry.size << '\n';
    } else if (std::string(argv[1]) == "7z") {
      std::ifstream in(argv[3], std::ios::binary);
      const std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
      archive* writer = archive_write_new();
      archive_entry* entry = archive_entry_new();
      archive_write_set_format_7zip(writer);
      archive_entry_set_pathname(entry, argv[4]);
      archive_entry_set_filetype(entry, AE_IFREG); archive_entry_set_perm(entry, 0644);
      archive_entry_set_size(entry, bytes.size());
      const bool success = archive_write_open_filename(writer, argv[2]) == ARCHIVE_OK &&
        archive_write_header(writer, entry) == ARCHIVE_OK &&
        archive_write_data(writer, bytes.data(), bytes.size()) == static_cast<la_ssize_t>(bytes.size()) &&
        archive_write_close(writer) == ARCHIVE_OK;
      archive_entry_free(entry); archive_write_free(writer);
      if (!success) throw std::runtime_error("7z fixture creation failed");
    } else throw std::runtime_error("unknown operation");
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

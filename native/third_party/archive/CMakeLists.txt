cmake_minimum_required(VERSION 3.18)
include(FetchContent)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# Pinned, offline source archives. No downloads during user builds.
FetchContent_Declare(qingqi_bzip_source URL "${CMAKE_CURRENT_SOURCE_DIR}/bzip2-1.0.8.tar.gz"
  URL_HASH SHA256=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269)
FetchContent_GetProperties(qingqi_bzip_source)
if(NOT qingqi_bzip_source_POPULATED)
  FetchContent_Populate(qingqi_bzip_source)
endif()
add_library(qingqi_bzip STATIC
  ${qingqi_bzip_source_SOURCE_DIR}/blocksort.c ${qingqi_bzip_source_SOURCE_DIR}/huffman.c
  ${qingqi_bzip_source_SOURCE_DIR}/crctable.c ${qingqi_bzip_source_SOURCE_DIR}/randtable.c
  ${qingqi_bzip_source_SOURCE_DIR}/compress.c ${qingqi_bzip_source_SOURCE_DIR}/decompress.c
  ${qingqi_bzip_source_SOURCE_DIR}/bzlib.c)
target_include_directories(qingqi_bzip PUBLIC "${qingqi_bzip_source_SOURCE_DIR}")
set(BZIP2_INCLUDE_DIR "${qingqi_bzip_source_SOURCE_DIR}" CACHE PATH "" FORCE)
set(BZIP2_LIBRARY qingqi_bzip CACHE STRING "" FORCE)
set(BZIP2_LIBRARIES qingqi_bzip CACHE STRING "" FORCE)

FetchContent_Declare(qingqi_xz_source URL "${CMAKE_CURRENT_SOURCE_DIR}/xz-5.8.4.tar.gz"
  URL_HASH SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9)
FetchContent_GetProperties(qingqi_xz_source)
if(NOT qingqi_xz_source_POPULATED)
  FetchContent_Populate(qingqi_xz_source)
endif()
set(XZ_NLS OFF CACHE BOOL "" FORCE)
set(XZ_THREADS no CACHE STRING "" FORCE)
add_subdirectory("${qingqi_xz_source_SOURCE_DIR}" "${qingqi_xz_source_BINARY_DIR}" EXCLUDE_FROM_ALL)
set(LIBLZMA_INCLUDE_DIR "${qingqi_xz_source_SOURCE_DIR}/src/liblzma/api" CACHE PATH "" FORCE)
set(LIBLZMA_LIBRARY liblzma CACHE STRING "" FORCE)
foreach(feature AUTO_DECODER EASY_ENCODER LZMA_PRESET)
  set(LIBLZMA_HAS_${feature} TRUE CACHE BOOL "Bundled liblzma API" FORCE)
endforeach()

FetchContent_Declare(qingqi_archive_source URL "${CMAKE_CURRENT_SOURCE_DIR}/libarchive-3.8.9.tar.xz"
  URL_HASH SHA256=888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde)
FetchContent_GetProperties(qingqi_archive_source)
if(NOT qingqi_archive_source_POPULATED)
  FetchContent_Populate(qingqi_archive_source)
endif()
foreach(feature MBEDTLS NETTLE OPENSSL LIBB2 LZ4 LZO ZSTD LIBXML2 EXPAT WIN32_XMLLITE
  PCREPOSIX PCRE2POSIX TAR CPIO CAT UNZIP TEST INSTALL XATTR ACL CNG WERROR)
  set(ENABLE_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(ENABLE_BZip2 ON CACHE BOOL "" FORCE)
set(ENABLE_LZMA ON CACHE BOOL "" FORCE)
set(ENABLE_ZLIB ON CACHE BOOL "" FORCE)
add_subdirectory("${qingqi_archive_source_SOURCE_DIR}" "${qingqi_archive_source_BINARY_DIR}" EXCLUDE_FROM_ALL)
target_include_directories(archive_static PUBLIC "${qingqi_archive_source_SOURCE_DIR}/libarchive")

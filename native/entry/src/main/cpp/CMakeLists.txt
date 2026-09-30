cmake_minimum_required(VERSION 3.12)
project(qingqi_hap_core LANGUAGES CXX)

find_program(QINGQI_CARGO cargo PATHS /opt/homebrew/opt/rustup/bin REQUIRED)
get_filename_component(QINGQI_CARGO_DIR "${QINGQI_CARGO}" DIRECTORY)
get_filename_component(QINGQI_COMPILER_DIR "${CMAKE_CXX_COMPILER}" DIRECTORY)
set(QINGQI_OHOS_LINKER "${QINGQI_COMPILER_DIR}/aarch64-unknown-linux-ohos-clang")
set(QINGQI_RUST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../rust_signer")
set(QINGQI_RUST_LIB "${QINGQI_RUST_DIR}/target/aarch64-unknown-linux-ohos/release/libqingqi_signer_bridge.a")
# Cargo owns the dependency graph (including path crates and build scripts).
# Run its incremental check whenever Ninja builds; do not hand-maintain a subset.
add_custom_target(qingqi_rust_signer
  BYPRODUCTS "${QINGQI_RUST_LIB}"
  COMMAND "${CMAKE_COMMAND}" -E env
    "PATH=${QINGQI_CARGO_DIR}:$ENV{PATH}"
    "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER=${QINGQI_OHOS_LINKER}"
    "CC_aarch64_unknown_linux_ohos=${QINGQI_OHOS_LINKER}"
    "CXX_aarch64_unknown_linux_ohos=${QINGQI_COMPILER_DIR}/aarch64-unknown-linux-ohos-clang++"
    "AR_aarch64_unknown_linux_ohos=${QINGQI_COMPILER_DIR}/llvm-ar"
    "${QINGQI_CARGO}" build --release --locked --target aarch64-unknown-linux-ohos
  WORKING_DIRECTORY "${QINGQI_RUST_DIR}"
  VERBATIM)

add_library(hap_core SHARED
  hap_core/zip_reader.cpp
  hap_core/signing_block.cpp
  hap_core/napi_bridge.cpp)
add_dependencies(hap_core qingqi_rust_signer)
target_compile_features(hap_core PRIVATE cxx_std_17)
target_compile_options(hap_core PRIVATE -Wall -Wextra)
target_link_libraries(hap_core PRIVATE "${QINGQI_RUST_LIB}" libace_napi.z.so z)

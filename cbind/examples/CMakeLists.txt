cmake_minimum_required(VERSION 3.14)
project(libp2p_cbind_examples CXX C)

# The generated bindings require C++20.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CBIND_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(GEN_DIR "${CBIND_DIR}/cpp_bindings")
set(BUILD_DIR "${CBIND_DIR}/../build")

if(APPLE)
  set(LIB_FILE "${BUILD_DIR}/libp2p.dylib")
elseif(WIN32)
  set(LIB_FILE "${BUILD_DIR}/libp2p.dll")
else()
  set(LIB_FILE "${BUILD_DIR}/libp2p.so")
endif()

if(NOT EXISTS "${GEN_DIR}/libp2p.hpp")
  message(FATAL_ERROR
    "Generated header ${GEN_DIR}/libp2p.hpp not found. "
    "Run `nimble genbindings_cpp` in cbind/ first.")
endif()
if(NOT EXISTS "${LIB_FILE}")
  message(FATAL_ERROR
    "Runtime library ${LIB_FILE} not found. Run `nimble buildffi` in cbind/ first.")
endif()

# ── Locate TinyCBOR (vendored inside the nim-ffi package) ────────────────────
# The generated header includes <tinycbor/cbor.h> and defers to the vendored
# sources. Override with -DTINYCBOR_VENDOR=/path/to/vendor if auto-detection
# fails.
if(NOT TINYCBOR_VENDOR)
  file(GLOB _ffi_vendors
    "${CBIND_DIR}/nimbledeps/pkgs2/ffi-*/ffi/codegen/templates/cpp/vendor"
    "${CBIND_DIR}/../nimbledeps/pkgs2/ffi-*/ffi/codegen/templates/cpp/vendor"
    "$ENV{HOME}/.nimble/pkgs2/ffi-*/ffi/codegen/templates/cpp/vendor")
  foreach(_v ${_ffi_vendors})
    if(EXISTS "${_v}/tinycbor/cbor.h")
      set(TINYCBOR_VENDOR "${_v}")
      break()
    endif()
  endforeach()
endif()
if(NOT TINYCBOR_VENDOR OR NOT EXISTS "${TINYCBOR_VENDOR}/tinycbor/cbor.h")
  message(FATAL_ERROR
    "Could not locate the vendored TinyCBOR sources. "
    "Pass -DTINYCBOR_VENDOR=/path/to/ffi/codegen/templates/cpp/vendor")
endif()

add_library(tinycbor STATIC
  "${TINYCBOR_VENDOR}/tinycbor/cborencoder.c"
  "${TINYCBOR_VENDOR}/tinycbor/cborencoder_close_container_checked.c"
  "${TINYCBOR_VENDOR}/tinycbor/cborparser.c"
  "${TINYCBOR_VENDOR}/tinycbor/cborparser_dup_string.c"
  "${TINYCBOR_VENDOR}/tinycbor/cborerrorstrings.c")
target_include_directories(tinycbor PUBLIC
  "${TINYCBOR_VENDOR}"
  "${TINYCBOR_VENDOR}/tinycbor")
set_property(TARGET tinycbor PROPERTY C_STANDARD 99)
set_property(TARGET tinycbor PROPERTY POSITION_INDEPENDENT_CODE ON)

find_package(Threads REQUIRED)

foreach(example echo gossipsub)
  add_executable(${example} "${example}.cpp")
  target_include_directories(${example} PRIVATE "${GEN_DIR}")
  target_link_libraries(${example} PRIVATE "${LIB_FILE}" tinycbor Threads::Threads)
  # So the loader finds libp2p.{so,dylib} next to it at runtime.
  set_target_properties(${example} PROPERTIES BUILD_RPATH "${BUILD_DIR}")
endforeach()

# Linux build for the rewcore_ffi plugin: delegates to ../src/CMakeLists.txt, which
# compiles the rewcore core into librewcore_ffi.so, and tells Flutter to bundle it.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "rewcore_ffi")
project(${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(rewcore_ffi_bundled_libraries
  $<TARGET_FILE:rewcore_ffi>
  PARENT_SCOPE
)

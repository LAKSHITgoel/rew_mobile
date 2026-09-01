# Builds the rewcore C++ core (from the monorepo ../../../core) into a single shared
# library named `rewcore_ffi`, which the Flutter FFI plugin bundles per platform and
# the app opens via dart:ffi. This is the plugin's real build logic; the surrounding
# platform folders come from `flutter create --template=plugin_ffi`.
cmake_minimum_required(VERSION 3.10)
project(rewcore_ffi LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CORE ${CMAKE_CURRENT_SOURCE_DIR}/../../../core)

add_library(rewcore_ffi SHARED
  ${CORE}/src/fft.cpp
  ${CORE}/src/biquad.cpp
  ${CORE}/src/dsp.cpp
  ${CORE}/src/peq.cpp
  ${CORE}/src/crossover.cpp
  ${CORE}/src/calibration.cpp
  ${CORE}/src/wav.cpp
  ${CORE}/ffi/rewcore_ffi.cpp
)

target_include_directories(rewcore_ffi PRIVATE ${CORE}/include ${CORE}/ffi)

# Keep the extern "C" symbols exported and undiscarded by LTO/stripping.
set_target_properties(rewcore_ffi PROPERTIES
  CXX_VISIBILITY_PRESET default
  VISIBILITY_INLINES_HIDDEN OFF
  PUBLIC_HEADER ${CORE}/ffi/rewcore_ffi.h
  OUTPUT_NAME "rewcore_ffi"
)

if(ANDROID)
  target_link_libraries(rewcore_ffi log)
endif()

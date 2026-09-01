# rewcore — platform-agnostic C++ measurement DSP.
# No OS audio APIs live here; this is the single source of truth for correctness
# and is compiled into a native lib for Android (NDK) and iOS, plus a desktop
# build for the test harness.

add_library(rewcore
  src/fft.cpp
  src/biquad.cpp
  src/dsp.cpp
  src/peq.cpp
  src/crossover.cpp
  src/calibration.cpp
  src/wav.cpp
  ffi/rewcore_ffi.cpp
)

target_include_directories(rewcore PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${CMAKE_CURRENT_SOURCE_DIR}/ffi
)

target_compile_options(rewcore PRIVATE -Wall -Wextra)

# ---- Desktop test harness -------------------------------------------------
add_executable(rewcore_tests tests/test_rewcore.cpp)
target_link_libraries(rewcore_tests PRIVATE rewcore)

add_test(NAME rewcore_tests COMMAND rewcore_tests)

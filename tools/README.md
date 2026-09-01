# tools — desktop harness

Desktop entry points for running `rewcore` against synthetic or recorded WAVs, outside
of a phone. Useful for development and CI.

The primary harness today is the unit-test binary `core/tests/test_rewcore.cpp`
(built as `rewcore_tests`, registered with CTest). It synthesizes signals with known
answers and asserts the DSP recovers them.

Future additions here: a small CLI that takes a real emitted-sweep WAV + a recording
WAV and prints the measured frequency response and recommended PEQ bands — handy for
cross-checking against REW's own exports (see the plan's verification section).

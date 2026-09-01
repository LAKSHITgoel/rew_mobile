/// rewcore_ffi bundles the native rewcore measurement library for each platform.
///
/// This package intentionally exposes no Dart API: it exists so Flutter compiles and
/// ships the native library (see `src/CMakeLists.txt` and the platform folders). The
/// app resolves the `rew_*` symbols directly with `dart:ffi` via
/// `RewcoreBindings.open()`. Regenerate typed bindings with `dart run ffigen`.
library rewcore_ffi;

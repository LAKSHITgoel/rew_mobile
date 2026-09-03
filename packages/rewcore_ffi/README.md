# rewcore_ffi — Flutter FFI plugin

Compiles the monorepo's C++ `core/` (rewcore) into a loadable native library so the
Flutter app can call it through `dart:ffi`. This holds the **non-generated** build
logic; the rest of the platform folders come from the plugin template.

## What's here

- `src/CMakeLists.txt` — builds the rewcore sources (`../../../core`) into
  `librewcore_ffi` (used on Android/Linux/Windows).
- `android/build.gradle` — points Android's `externalNativeBuild` at `src/CMakeLists.txt`.
- `ios/rewcore_ffi.podspec` — compiles the core for iOS/macOS (see the symlink note in
  the podspec).
- `ffigen.yaml` — regenerate Dart bindings from `core/ffi/rewcore_ffi.h`.
- `pubspec.yaml` — declares this as an `ffiPlugin`.

## Bootstrap

Already done — all five platform folders are present (`android/`, `ios/`, `linux/`,
`macos/`, `windows/`). The iOS and macOS podspecs read the core through a `core`
symlink in each of those folders pointing at `../../../core`; if a checkout loses them
(some archives don't preserve symlinks), recreate with:

```sh
cd packages/rewcore_ffi && ln -sfn ../../../core ios/core && ln -sfn ../../../core macos/core
```

The app depends on it from `app/pubspec.yaml`:

```yaml
dependencies:
  rewcore_ffi:
    path: ../packages/rewcore_ffi
```

The app opens the library via `RewcoreBindings.open()` — `librewcore_ffi.so` on
Android/Linux, `rewcore_ffi.dll` on Windows, and process symbols on iOS/macOS.

## Symbols

The library must export the `rew_*` C functions from `core/ffi/rewcore_ffi.h`. The
CMake sets default visibility and disables dead-code stripping so FFI lookups resolve.

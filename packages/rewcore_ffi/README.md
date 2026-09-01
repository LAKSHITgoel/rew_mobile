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

## Bootstrap (on a machine with the Flutter SDK)

```sh
cd packages
flutter create --template=plugin_ffi --platforms=android,ios,linux,macos,windows \
  --org com.rewmobile rewcore_ffi_scaffold
# Merge the generated scaffold's missing platform folders into this package
# (keeping the src/CMakeLists.txt, gradle, podspec, and pubspec here).
```

Then depend on it from the app (`app/pubspec.yaml`):

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

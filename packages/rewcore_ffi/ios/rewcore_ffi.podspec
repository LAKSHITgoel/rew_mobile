#
# iOS/macOS build for the rewcore_ffi plugin. CocoaPods compiles the rewcore C++
# sources into the app; because the symbols are then in the process, the Dart side
# opens them with DynamicLibrary.process().
#
# CocoaPods will not glob into a symlinked DIRECTORY: with `core` symlinked here
# and source_files set to 'core/src/**/*.cpp', the pod built with no sources at
# all. The app still linked and launched — and then had no DSP in it, so every
# rew_* lookup would have failed at the first measurement.
#
# So the sources are symlinked FILE BY FILE into Classes/, which is what Flutter's
# own FFI plugin template does. `core` stays for the header search path (-I needs
# no globbing). After changing the file list here, re-run `pod install`.
#
Pod::Spec.new do |s|
  s.name             = 'rewcore_ffi'
  s.version          = '0.1.0'
  s.summary          = 'rewcore C++ measurement DSP as an FFI plugin.'
  s.description      = 'Compiles the shared rewcore core for iOS/macOS.'
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'rew_mobile' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/*.cpp', 'Classes/*.h'
  s.public_header_files = 'Classes/*.h'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/core/include" "$(PODS_TARGET_SRCROOT)/core/ffi"',
    'DEFINES_MODULE' => 'YES',
    # Keep the extern "C" symbols so DynamicLibrary.process() can find them.
    'DEAD_CODE_STRIPPING' => 'NO',
  }
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
end

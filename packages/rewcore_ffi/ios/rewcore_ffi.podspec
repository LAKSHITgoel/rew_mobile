#
# iOS/macOS build for the rewcore_ffi plugin. CocoaPods compiles the rewcore C++
# sources into the app; because the symbols are then in the process, the Dart side
# opens them with DynamicLibrary.process().
#
# NOTE: CocoaPods wants source files under the podspec directory. The core lives at
# ../../../core, so on bootstrap create a symlink once:
#     ln -s ../../../core packages/rewcore_ffi/ios/core
# (or copy it in a prepare step). The globs below then pick it up.
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

  s.source_files     = 'core/src/**/*.cpp', 'core/ffi/*.cpp', 'core/ffi/*.h'
  s.public_header_files = 'core/ffi/*.h'
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

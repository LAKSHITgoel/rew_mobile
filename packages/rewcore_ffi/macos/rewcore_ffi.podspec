#
# macOS build for the rewcore_ffi plugin. Mirrors ios/rewcore_ffi.podspec: CocoaPods
# compiles the rewcore C++ sources into the app, so the Dart side opens them with
# DynamicLibrary.process().
#
# NOTE: CocoaPods wants source files under the podspec directory. The core lives at
# ../../../core, so the `core` symlink here points at it and the globs below pick it up.
#
Pod::Spec.new do |s|
  s.name             = 'rewcore_ffi'
  s.version          = '0.1.0'
  s.summary          = 'rewcore C++ measurement DSP as an FFI plugin.'
  s.description      = 'Compiles the shared rewcore core for iOS/macOS.'
  s.homepage         = 'https://example.com'
  # Marked private rather than pointing at a LICENSE file: there is no LICENSE
  # in this repo, and naming one that does not exist makes `pod install` warn on
  # every run. This says only that the pod is not published — it makes no claim
  # about the terms the code is under, which is the repo owner's call.
  s.license          = { :type => 'Private' }
  s.author           = { 'rew_mobile' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  # Per-file symlinks, not a directory symlink: CocoaPods will not glob into a
  # symlinked directory, and the pod then builds with no sources at all. See the
  # note in ../ios/rewcore_ffi.podspec.
  s.source_files     = 'Classes/*.cpp', 'Classes/*.h'
  s.public_header_files = 'Classes/*.h'
  s.dependency 'FlutterMacOS'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/core/include" "$(PODS_TARGET_SRCROOT)/core/ffi"',
    'DEFINES_MODULE' => 'YES',
    # Keep the extern "C" symbols so DynamicLibrary.process() can find them.
    'DEAD_CODE_STRIPPING' => 'NO',
  }
  s.osx.deployment_target = '10.15'
end

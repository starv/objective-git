#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Patches the vendored Quick/Nimble/ZipArchive Carthage checkouts under
# Carthage/Checkouts/ so their Xcode projects build under a modern Xcode
# toolchain, which:
#
#   1. Rejects opening/building any project containing a macOS deployment
#      target below its supported floor ("the range of supported deployment
#      target versions is 12.0 to 27.0.x"). Quick and Nimble are pinned at
#      MACOSX_DEPLOYMENT_TARGET = 10.10, ZipArchive at 10.8.
#   2. Treats -Wstrict-prototypes as an error. Nimble's
#      Sources/NimbleObjectiveC/DSL.m defines several zero-argument C
#      functions (NMB_beTruthy, NMB_beFalsy, NMB_beTrue, NMB_beFalse,
#      NMB_beNil, NMB_beEmpty, NMB_raiseException) using old-style empty
#      parens `Type Name() { ... }` instead of `Type Name(void) { ... }`.
#      Their own header (DSL.h) already declares them correctly with
#      `(void)` -- only the .m definitions are stale.
#   3. No longer ships a standalone libswiftXCTest to link against.
#      Nimble's `Nimble-macOS`/`Nimble-iOS`/`Nimble-tvOS` targets pass
#      `-weak-lswiftXCTest` in OTHER_LDFLAGS (a belt-and-suspenders weak
#      link added back when Swift's XCTest assertion support briefly lived
#      in a separate dylib). Being a *weak* link doesn't help here: the
#      linker still needs to locate the library file to link against it at
#      all, weak or not, and modern toolchains don't ship one -- so this
#      fails as a hard "library not found" error, not a soft/missing-symbol
#      warning. XCTest functionality itself is unaffected; it's still
#      linked via the adjacent `-weak_framework XCTest` flag, which stays.
#   4. jspahrsummers/xcconfigs' Base/Configurations/Debug.xcconfig sets
#      `OTHER_CODE_SIGN_FLAGS = --digest-algorithm=sha1 --timestamp=none`
#      (a ~2015-era speed optimization for local ad-hoc signing). Modern
#      codesign refuses SHA1-only signatures outright ("signing with only
#      SHA1 not allowed"), which fails at the very last step of building
#      ObjectiveGit-MacTests -- after every source file has already
#      compiled and linked. Only the `--digest-algorithm=sha1` half is
#      removed; `--timestamp=none` is untouched (still wanted for local
#      ad-hoc signing).
#   5. Quick-macOS and Nimble-macOS hardcode `VALID_ARCHS = x86_64`, so on
#      an Apple Silicon host their .swiftmodule is only ever built for
#      x86_64-apple-macos, which the arm64-only ObjectiveGit-MacTests
#      target then can't import ("Module file ... is incompatible with
#      this Swift compiler: built for incompatible target"). The
#      restriction is removed entirely rather than replaced with a
#      hardcoded "arm64", so these targets fall back to Xcode's standard
#      architecture set on whatever host builds them.
#
# This script is idempotent: running it against an already-patched checkout
# (e.g. because script/bootstrap ran twice, or `git submodule update` was
# re-run without resetting a prior patch) is a safe no-op. It is invoked
# automatically by script/bootstrap after submodules are checked out, so a
# fresh clone gets a working build without any manual, easily-forgotten,
# one-off edit to the submodule checkout itself (which `git submodule
# update` would otherwise silently discard on the next sync).

begin
  require 'xcodeproj'
rescue LoadError
  warn <<~MESSAGE
    *** error: the 'xcodeproj' gem is required to patch the Carthage-vendored
    *** Quick/Nimble/ZipArchive checkouts for this Xcode toolchain, but it is
    *** not available to '#{RbConfig.ruby}'.
    ***
    *** Install it with:
    ***     gem install xcodeproj
    ***
    *** If you have multiple Ruby installations (e.g. system Ruby vs. a
    *** Homebrew-installed Ruby), make sure the one on your PATH is the one
    *** the gem was installed for.
  MESSAGE
  exit 1
end

ROOT = File.expand_path('..', __dir__)

MIN_MACOS_DEPLOYMENT_TARGET = 12.0

DEPENDENCY_PROJECTS = [
  'Carthage/Checkouts/Quick/Quick.xcodeproj',
  'Carthage/Checkouts/Nimble/Nimble.xcodeproj',
  'Carthage/Checkouts/ZipArchive/ZipArchive.xcodeproj',
].freeze

def patch_deployment_targets(project_path)
  full_path = File.join(ROOT, project_path)
  unless File.directory?(full_path)
    warn "*** Skipping #{project_path} (not checked out)"
    return
  end

  project = Xcodeproj::Project.open(full_path)
  changed = false

  (project.build_configurations + project.targets.flat_map(&:build_configurations)).each do |config|
    value = config.build_settings['MACOSX_DEPLOYMENT_TARGET']
    next unless value

    current = value.to_s.to_f
    next if current >= MIN_MACOS_DEPLOYMENT_TARGET

    config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = MIN_MACOS_DEPLOYMENT_TARGET.to_s
    changed = true
  end

  if changed
    project.save
    puts "*** Bumped MACOSX_DEPLOYMENT_TARGET to #{MIN_MACOS_DEPLOYMENT_TARGET} in #{project_path}"
  else
    puts "*** #{project_path} already has MACOSX_DEPLOYMENT_TARGET >= #{MIN_MACOS_DEPLOYMENT_TARGET}"
  end
end

def patch_nimble_strict_prototypes
  dsl_m = File.join(ROOT, 'Carthage/Checkouts/Nimble/Sources/NimbleObjectiveC/DSL.m')
  unless File.file?(dsl_m)
    warn '*** Skipping Nimble strict-prototypes patch (DSL.m not checked out)'
    return
  end

  source = File.read(dsl_m)
  original = source.dup

  # Only touch zero-argument function *definitions* (immediately followed by
  # `{`), matching them by the exact old-style empty-parens signatures Nimble
  # ships. This is a straight substitution, not a general regex sweep, so it
  # can't accidentally touch an unrelated `Foo()` call expression elsewhere.
  %w[NMB_beTruthy NMB_beFalsy NMB_beTrue NMB_beFalse NMB_beNil NMB_beEmpty NMB_raiseException].each do |name|
    source = source.sub(/\b#{name}\(\)(\s*\{)/, "#{name}(void)\\1")
  end

  if source != original
    File.write(dsl_m, source)
    puts '*** Patched Nimble/Sources/NimbleObjectiveC/DSL.m for -Wstrict-prototypes'
  else
    puts '*** Nimble/Sources/NimbleObjectiveC/DSL.m already patched for -Wstrict-prototypes'
  end
end

def patch_intel_only_valid_archs(project_path)
  full_path = File.join(ROOT, project_path)
  unless File.directory?(full_path)
    warn "*** Skipping #{project_path} (not checked out)"
    return
  end

  project = Xcodeproj::Project.open(full_path)
  changed = false

  project.targets.each do |target|
    target.build_configuration_list.build_configurations.each do |config|
      next unless config.build_settings['VALID_ARCHS'] == 'x86_64'

      # Drop the hardcoded Intel-only restriction entirely rather than
      # replacing it with a hardcoded "arm64" -- this lets these targets
      # fall back to Xcode's standard architecture set (ARCHS_STANDARD),
      # matching whatever ObjectiveGit-Mac/ObjectiveGit-MacTests build for
      # (currently arm64-only) on any host, instead of re-hardcoding a
      # single architecture that will need revisiting again later.
      config.build_settings.delete('VALID_ARCHS')
      changed = true
    end
  end

  if changed
    project.save
    puts "*** Removed hardcoded VALID_ARCHS = x86_64 from #{project_path}"
  else
    puts "*** #{project_path} has no hardcoded VALID_ARCHS = x86_64 restriction"
  end
end

def patch_nimble_missing_swift_xctest_lib
  project_path = File.join(ROOT, 'Carthage/Checkouts/Nimble/Nimble.xcodeproj')
  unless File.directory?(project_path)
    warn '*** Skipping Nimble -weak-lswiftXCTest patch (Nimble.xcodeproj not checked out)'
    return
  end

  project = Xcodeproj::Project.open(project_path)
  changed = false

  project.targets.each do |target|
    target.build_configuration_list.build_configurations.each do |config|
      flags = config.build_settings['OTHER_LDFLAGS']
      next unless flags.is_a?(Array) && flags.include?('-weak-lswiftXCTest')

      flags.delete('-weak-lswiftXCTest')
      changed = true
    end
  end

  if changed
    project.save
    puts '*** Removed stale -weak-lswiftXCTest from Nimble.xcodeproj OTHER_LDFLAGS'
  else
    puts '*** Nimble.xcodeproj already has no -weak-lswiftXCTest linker flag'
  end
end

def patch_xcconfigs_sha1_code_sign_flag
  debug_xcconfig = File.join(ROOT, 'Carthage/Checkouts/xcconfigs/Base/Configurations/Debug.xcconfig')
  unless File.file?(debug_xcconfig)
    warn '*** Skipping xcconfigs SHA1 code-sign patch (Debug.xcconfig not checked out)'
    return
  end

  source = File.read(debug_xcconfig)
  original = source.dup

  source = source.sub(
    /^OTHER_CODE_SIGN_FLAGS = --digest-algorithm=sha1 --timestamp=none$/,
    'OTHER_CODE_SIGN_FLAGS = --timestamp=none'
  )

  if source != original
    File.write(debug_xcconfig, source)
    puts '*** Removed --digest-algorithm=sha1 from xcconfigs Base/Configurations/Debug.xcconfig'
  else
    puts '*** xcconfigs Base/Configurations/Debug.xcconfig already has no --digest-algorithm=sha1'
  end
end

DEPENDENCY_PROJECTS.each { |path| patch_deployment_targets(path) }
DEPENDENCY_PROJECTS.each { |path| patch_intel_only_valid_archs(path) }
patch_nimble_strict_prototypes
patch_nimble_missing_swift_xctest_lib
patch_xcconfigs_sha1_code_sign_flag

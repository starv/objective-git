# objective-git macOS modernization — design

## Purpose

objective-git hasn't been updated since May 2021 and no longer builds on current Xcode. The goal is a working `.xcframework` build of objective-git for macOS on the latest Xcode, suitable as the git engine underneath a new git client app. The client needs full network operations: clone/fetch/push over both HTTPS and SSH.

## Context (from investigation)

- Vendored C dependencies are submodules pinned to 2019-era commits: libgit2 ~v0.28, libssh2 ~1.8.0, OpenSSL ~1.0.2p. OpenSSL 1.0.2 has been EOL since Dec 2019 and is the least likely of the three to compile cleanly against a modern SDK/Clang.
- These libraries are built from source (not vendored binaries) via `script/update_libgit2`, `script/update_libgit2_ios`, `script/update_libssh2_ios`, `script/update_libssl_ios`, invoked from Xcode Run Script build phases and `script/bootstrap`/`script/cibuild`.
- `script/bootstrap` hardcodes Homebrew paths under `/usr/local`, which breaks on Apple Silicon's default `/opt/homebrew` prefix.
- Deployment targets (`MACOSX_DEPLOYMENT_TARGET = 10.10`, `IPHONEOS_DEPLOYMENT_TARGET = 9.3`) are far below what's realistic for a modern SDK.
- Test dependencies (Quick 2.2.1, Nimble 8.1.2, ZipArchive 2.2.3, jspahrsummers/xcconfigs) are pulled via Carthage and are all ~2019-era.
- Last verified-good CI toolchain was Xcode 12.2 (Travis, now defunct for OSS).
- A separate audit of `ObjectiveGit/*.m`/`*.h` found 371 libgit2 C API call sites across 114 files, concentrated in `GTRepository.m`, `GTIndex.m`, `GTRemote.m`, `GTReference.m`, `GTSubmodule.m` (~53% of call sites in the top 10 files). The wrapper already uses versioned `GIT_*_OPTIONS_INIT` / `GIT_REMOTE_CALLBACKS_INIT` macros throughout, so most of the 0.28→1.9 API drift is source-compatible or a simple rename, not a structural rewrite:
  - `git_cred*` / `GIT_CREDTYPE_*` → `git_credential*` / `GIT_CREDENTIAL_*` (isolated to `GTCredential.m`, `GTCredential.h`, `GTCredential+Private.h`, 17 call sites).
  - `git_transfer_progress*` → `git_indexer_progress*` (in `GTRepository.m`, `GTRepository+RemoteOperations.m`, `GTRepository+Merging.m`).
  - `GTIndex.m` (conflict iterator) and `GTSubmodule.m` were not fully verified against current headers — treat as risk pockets.
- No SPM support exists anywhere in the project today.

## Scope decisions (confirmed with user)

- **Platform**: macOS only. No iOS target/scheme carried forward.
- **Architecture**: arm64 only (Apple Silicon). No universal/Intel support in this pass.
- **Network transport**: full support required — both HTTPS and SSH remotes.
- **Crypto/TLS backend**: replace OpenSSL entirely.
  - libgit2's HTTPS uses Apple's native **Secure Transport** (system-provided, no build step, no long-term maintenance burden).
  - libssh2 needs its own crypto backend for key operations (Secure Transport doesn't cover this) — use **mbedTLS**, vendored and built from source.
- **libgit2/libssh2 versions**: bump to latest stable tags (currently libgit2 1.9.x line, libssh2 1.11.x line) rather than an intermediate version.
- **Test dependencies**: migrate off Carthage to **Swift Package Manager** for Quick, Nimble, and ZipArchive.
- **Test suite**: in scope — get the existing Quick/Nimble spec suite running, not just the framework build.
- **CI**: explicitly out of scope. This is a local build fix only; no GitHub Actions or other CI replacement.
- **Packaging**: output an `.xcframework` via `xcodebuild -create-xcframework`.

## Architecture

`ObjectiveGitFramework.xcodeproj` remains the project container. Three vendored C libraries — libgit2, libssh2, mbedTLS — are built from source via modernized shell/CMake scripts into arm64 static libraries targeting a current macOS deployment target. These static libs are linked into the existing ObjectiveGit framework target the same way they are today (Run Script build phase + header search paths + link phase), just repointed at the new versions/paths. The final build artifact is packaged as an `.xcframework`.

## Components

1. **Submodule bumps**
   - libgit2 → latest 1.9.x tag.
   - libssh2 → latest 1.11.x tag.
   - Remove the OpenSSL submodule entirely.
   - Add mbedTLS as a new submodule, pinned to a version libssh2's own release notes/CI matrix confirm as compatible.

2. **Build scripts**
   - Rewrite `script/update_libgit2`: CMake invocation with `-DUSE_HTTPS=SecureTransport`, SSH enabled via libssh2, `-DCMAKE_OSX_ARCHITECTURES=arm64`, current `CMAKE_OSX_DEPLOYMENT_TARGET`. Exact current flag names must be verified against the real libgit2 1.9.x `CMakeLists.txt` during implementation (flag names/semantics shift between major versions).
   - Add `script/update_mbedtls`: builds mbedTLS statically for arm64.
   - Rewrite `script/update_libssh2`: builds against mbedTLS as the crypto backend (`-DCRYPTO_BACKEND=mbedTLS`), arm64 only.
   - Delete `script/update_libgit2_ios`, `script/update_libssh2_ios`, `script/update_libssl_ios` (no iOS target).
   - Fix `script/bootstrap`: resolve the Homebrew prefix via `brew --prefix` instead of hardcoding `/usr/local`.

3. **Xcode project settings**
   - Raise `MACOSX_DEPLOYMENT_TARGET` to 15.0 (Sequoia) as a concrete default — recent enough to avoid legacy-SDK friction, adjustable during implementation if a specific need calls for lower.
   - `ARCHS = arm64` (drop other architectures).
   - Remove or retire any iOS target/scheme.
   - Add an `.xcframework` packaging step (`xcodebuild -create-xcframework`).

4. **Objective-C source changes**
   - Apply the two confirmed renames: `git_cred*` → `git_credential*` (`GTCredential.m`, `GTCredential.h`, `GTCredential+Private.h`), `git_transfer_progress*` → `git_indexer_progress*` (`GTRepository.m`, `GTRepository+RemoteOperations.m`, `GTRepository+Merging.m`).
   - Compile against the real 1.9.x headers and fix whatever else the compiler surfaces — the rename list above is based on a grep-based estimate, not a real compile, and is known to be unverified for `GTIndex.m` and `GTSubmodule.m` specifically.

5. **Test dependencies**
   - Remove `Cartfile`, `Cartfile.private`, `Cartfile.resolved`.
   - Add Quick, Nimble, and ZipArchive as Swift Package dependencies on the test target via the project's package dependencies.
   - Verify ZipArchive-based fixture unpacking still works post-migration, and that specs don't reference any of the renamed libgit2 symbols indirectly.

## Build pipeline / data flow

```
submodule init
  → build mbedTLS (static, arm64)
  → build libssh2 (linked against mbedTLS)
  → build libgit2 (linked against libssh2; HTTPS via system Secure Transport — no build step for that part)
  → Xcode links resulting static libs into the ObjectiveGit framework target
  → xcodebuild -create-xcframework produces the distributable artifact
```

## Risk areas

- Current libgit2's exact CMake flags for Secure Transport/libssh2 integration need verification at implementation time; flag names have shifted across libgit2's major versions since 0.28.
- mbedTLS↔libssh2 version compatibility needs a deliberately chosen known-good pair, not just "latest of both."
- The Objective-C rename list is an estimate; treat the real compile as the source of truth and budget time for fixes it surfaces, especially in `GTIndex.m` and `GTSubmodule.m`.
- ZipArchive-based test fixtures may need verification after the Carthage → SPM migration.

## Testing

- **Primary bar**: the framework builds clean (no errors) on latest Xcode, arm64 macOS.
- **Secondary bar**: the existing Quick/Nimble spec suite runs and passes, or any newly-failing specs are triaged and understood (not silently ignored).
- **Manual smoke test**: a real clone over HTTPS and a real clone over SSH against live repos, to confirm the new Secure Transport/mbedTLS backends work end-to-end — unit tests are unlikely to meaningfully exercise real network/credential paths.

## Out of scope

- CI (GitHub Actions or otherwise).
- iOS target.
- Universal/Intel (x86_64) architecture support.

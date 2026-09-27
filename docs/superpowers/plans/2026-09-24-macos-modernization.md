# macOS Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ObjectiveGitFramework.xcodeproj` build a working macOS/arm64-only `.xcframework` on current Xcode, with libgit2 1.9.x/libssh2 1.11.x replacing the EOL 0.28/OpenSSL stack, Secure Transport + mbedTLS replacing OpenSSL, and the Quick/Nimble/ZipArchive test suite running via SPM instead of Carthage submodules.

**Architecture:** Three vendored C libraries (mbedTLS → libssh2 → libgit2, in that build order) are compiled from source into static `arm64` archives under `External/build`, via rewritten shell/CMake scripts wired into three Xcode aggregate targets. The `ObjectiveGit-Mac` framework target links those archives plus system Secure Transport, drops all iOS targets/scripts, and gets its deployment target raised and its architecture pinned. Test dependencies move from Carthage git-submodule subprojects to native SPM package dependencies. A new script produces the final `.xcframework`.

**Tech Stack:** Objective-C, CMake, libgit2 1.9.x (C), libssh2 1.11.x (C), OpenSSL 3.5.x LTS (C) — see Tasks 18-22 amendment note below — Xcode project format (`.pbxproj`), Swift Package Manager, Quick/Nimble (XCTest-based BDD), FlowDeck (build/test/simulator tooling — see Global Constraints).

> **Amendment (post-Task-17, recorded in the SDD ledger):** Task 17's manual smoke test conclusively root-caused a real, unfixable-in-small-scope bug: mbedTLS cannot parse OpenSSH's `openssh-key-v1` private-key format (`ssh-keygen`'s default output for every key type since 2018), and separately never implemented Ed25519 signing at all (`LIBSSH2_ED25519 0`) — so SSH client-key auth was broken for virtually all real-world keys. The human decided to reconsider the crypto backend rather than ship with that gap. **Tasks 18-22 below supersede the original mbedTLS-for-SSH design** (Tasks 1, 3, 4, 7, 8's mbedTLS-specific pieces): mbedTLS is fully removed and replaced with OpenSSL (vendored from source, statically linked, same "zero Homebrew/user-tooling runtime dependency" constraint applies), scoped only to libssh2's SSH-crypto backend — HTTPS stays on Secure Transport, untouched. This is a deliberate deviation from this plan's original Global Constraints text below (same pattern as Task 15's Carthage-vs-SPM reversal) — the Crypto/TLS and exact-version-pins bullets immediately below describe the ORIGINAL (now superseded) design; treat Tasks 18-22 as the authoritative current state for anything they touch.

**Spec:** `docs/superpowers/specs/2026-09-24-macos-modernization-design.md`

## Global Constraints

- **Platform: macOS only, arm64 only.** No iOS target, scheme, or Intel/universal architecture support survives this plan.
- **Full network support required**: both HTTPS and SSH remotes must work end-to-end (clone/fetch/push).
- **Crypto/TLS** *(SUPERSEDED by Tasks 18-22 — see amendment note above; kept here for historical context)*: ~~OpenSSL is removed entirely.~~ HTTPS goes through libgit2's Secure Transport backend (system-provided, unaffected by the amendment). ~~SSH's crypto needs go through mbedTLS (vendored, built from source).~~ **Current: SSH's crypto goes through OpenSSL (vendored, built from source, statically linked) — mbedTLS is removed entirely.**
- **Exact version pins** (research-verified against upstream GitHub tags/CMake sources on 2026-09-24, not asserted from memory):
  - libgit2: tag `v1.9.7`
  - libssh2: tag `libssh2-1.11.1`
  - ~~mbedTLS: tag `v3.6.7`~~ *(superseded — see Tasks 18-22)* **OpenSSL: tag `openssl-3.5.8`** (OpenSSL 3.5 LTS line, supported until 2030-04-08; research-verified against `openssl/openssl`'s real tag list on the amendment date).
- **Deployment target**: `MACOSX_DEPLOYMENT_TARGET = 15.0`.
- **Test dependencies**: Quick, Nimble, ZipArchive move from Carthage git submodules (`Carthage/Checkouts/*`) to Swift Package Manager. `Cartfile`/`Cartfile.private`/`Cartfile.resolved` and the `Carthage/Checkouts/*` submodules are removed.
- **Test suite is in scope**: the existing `ObjectiveGitTests` Quick/Nimble suite must run, not just "the framework builds."
- **CI is out of scope**: no GitHub Actions replacement. `script/cibuild` only gets touched where it directly breaks due to iOS target removal (dead-reference cleanup), not as a CI initiative.
- **Packaging**: final artifact is `ObjectiveGit.xcframework`, produced via `xcodebuild -create-xcframework`.
- **Zero runtime dependency on Homebrew or any user-installed tooling.** Homebrew (`cmake`/`libtool`/`autoconf`/`automake`/`pkg-config`) is a build-time-only convenience for the developer's machine; OpenSSL's own build additionally needs Perl ≥5.10 (macOS system Perl satisfies this — not a Homebrew dependency, and OpenSSL vendors its own fallback for the one non-core Perl module its build script needs, so no CPAN install is required either). The shipped framework must be self-contained — every third-party library (`libgit2`, `libssh2`, ~~mbedTLS~~ **OpenSSL, superseded by Tasks 18-22**) statically linked into the framework binary, with the only external dependencies being macOS system frameworks/libraries (`Security.framework`, `libcurl`) — so a macOS App Store sandboxed app can link against it with nothing to install. (Verified explicitly in Task 17, Step 1, and re-verified in Task 22.)
- **Tooling rule for this plan's own execution**: whenever a task's verification step needs to build, run, or test the Xcode project, use the **flowdeck** skill (`Skill(flowdeck)`), never raw `xcodebuild`/`xcrun`/`simctl` invoked directly by the executor. This rule governs how the *executor* verifies work; it does not apply to shell scripts under `script/` that legitimately shell out to `xcodebuild` as part of the shipped build/packaging tooling (e.g. `script/create_xcframework`).
- **The rename list for libgit2 0.28→1.9 is not exhaustive.** Two renames are confirmed by grep audit (`git_cred*`→`git_credential*`, `git_transfer_progress*`→`git_indexer_progress*`); a third confirmed-broken symbol was found during plan research (`GIT_BUF_INIT_CONST` and `git_buf_free`/`git_buf_grow`/`git_buf_set` no longer exist in the public 1.9 `git2/buffer.h`). Treat a real compile against the real 1.9.7 headers as the source of truth for anything beyond what this plan enumerates.

## Review Focus

- **Credential type enum values surviving the rename**: `GTCredentialType` publicly re-exports `GIT_CREDTYPE_*`/`GIT_CREDENTIAL_*` integer values — a client hardcoding the old numeric values must keep working identically after the rename. (Covered in Task 10.)
- **`git_buf`-based data round-tripping silently corrupting bytes**: `NSData+Git.m`, `GTFilter.m`, `GTFilterList.m` construct/consume `git_buf` for binary blob content; since `git_buf` became output-only in 1.x (`GIT_BUF_INIT_CONST` is gone), a naive fix could compile but truncate or NUL-terminate binary data incorrectly. (Covered in Task 12.)
- **`git_submodule_set_ignore` deprecation/removal silently no-op'ing**: `GTSubmodule.m`'s `submoduleByUpdatingIgnoreRule:` calls this function, which is soft/hard-deprecated by libgit2 1.9; a caller expecting a real ignore-rule change should get an error or a real effect, not silent success. (Covered in Task 13.)
- **SPM-vended Quick/Nimble/ZipArchive not resolving `@import Quick;`-style Clang module imports**: every spec file in `ObjectiveGitTests` uses `@import Quick;`/`@import Nimble;`/`@import ZipArchive;` (Clang module syntax, not `#import <Quick/Quick.h>`). SPM library targets don't always vend an importable module the same way Carthage-built `.framework`s did. (Covered in Task 15.)
- **Network-failure paths going unverified by unit tests**: none of the existing specs hit live remotes, so an auth-should-fail case (bad SSH key, bad HTTPS password) could silently hang or crash under the new Secure Transport/SSH-crypto backends instead of surfacing the expected `NSError`, and nothing in the automated suite would catch it. (Covered in Task 17's manual smoke test.)
- **SSH key-format/algorithm support must cover real-world default keys, not just a legacy-PEM happy path**: Task 17 found the original mbedTLS backend silently failed to even parse `ssh-keygen`'s modern default key format (`openssh-key-v1`) and never implemented Ed25519 signing — a naive "SSH clone succeeds with some key" check would have missed both. (Covered in Task 22's re-verification.)

---

### Task 1: Bump submodules, remove OpenSSL, add mbedTLS

**Files:**
- Modify: `.gitmodules`
- Modify (submodule pointers): `External/libgit2`, `External/libssh2`
- Delete (submodule): `External/openssl`
- Create (submodule): `External/mbedtls`

**Interfaces:**
- Produces: checked-out submodule working trees at `External/libgit2` (tag `v1.9.7`), `External/libssh2` (tag `libssh2-1.11.1`), `External/mbedtls` (tag `v3.6.7`) — consumed by Tasks 3–5's build scripts and Task 12's header-verification steps.

- [ ] **Step 1: Initialize existing submodules at their current pins, to have a baseline to diff from**

```bash
git submodule update --init External/libgit2 External/libssh2 External/openssl
git -C External/libgit2 log -1 --oneline
```
Expected: three directories populate with source; `git submodule status` no longer shows `-` for these three paths.

- [ ] **Step 2: Bump libgit2 and libssh2 to the pinned tags**

```bash
git -C External/libgit2 fetch --tags
git -C External/libgit2 checkout v1.9.7
git -C External/libssh2 fetch --tags
git -C External/libssh2 checkout libssh2-1.11.1
```

- [ ] **Step 3: Remove the OpenSSL submodule entirely**

```bash
git submodule deinit -f External/openssl
git rm -f External/openssl
rm -rf .git/modules/External/openssl
```
Then remove its `[submodule "openssl"]` stanza from `.gitmodules`.

- [ ] **Step 4: Add the mbedTLS submodule pinned to v3.6.7**

```bash
git submodule add https://github.com/Mbed-TLS/mbedtls.git External/mbedtls
git -C External/mbedtls fetch --tags
git -C External/mbedtls checkout v3.6.7
git -C External/mbedtls submodule update --init --recursive
```
mbedTLS 3.6.x itself vendors third-party test/framework submodules; `--recursive` avoids a later surprise if the build ever touches them (it won't, since `ENABLE_TESTING=OFF`/`ENABLE_PROGRAMS=OFF` in Task 3, but the checkout should still be clean).

- [ ] **Step 5: Verify submodule state**

```bash
git submodule status
```
Expected: `External/libgit2` pinned at the `v1.9.7` commit, `External/libssh2` at `libssh2-1.11.1`, `External/mbedtls` at `v3.6.7`, no `External/openssl` entry, no `-` prefixes (all initialized).

- [ ] **Step 6: Commit**

```bash
git add .gitmodules External/libgit2 External/libssh2 External/mbedtls
git commit -m "Bump libgit2 to 1.9.7, libssh2 to 1.11.1, replace OpenSSL submodule with mbedTLS 3.6.7"
```

---

### Task 2: Fix `script/bootstrap` for Apple Silicon Homebrew, drop the libssh2-via-Homebrew assumption

**Files:**
- Modify: `script/bootstrap`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a bootstrap script that no longer requires `sudo` or assumes `/usr/local`; downstream scripts (Tasks 3–5) rely on `brew --prefix`-resolved tool paths (`cmake`) being on `PATH` after this script runs.

**Context:** The current script hardcodes `expected_prefix=/usr/local` and creates `sudo`-owned symlinks from `/usr/local/{lib,include}/libssh2*` into the real Homebrew prefix, purely so libgit2's macOS CMake build can find Homebrew's libssh2. Since Task 4 vendors and builds libssh2 from the submodule instead of depending on a Homebrew formula, that whole workaround becomes unnecessary — deleting it, rather than patching it to use `brew --prefix`, is what actually fixes the Apple Silicon breakage the spec called out (there is no Homebrew-provided-libssh2 path left to get wrong).

- [ ] **Step 1: Rewrite `script/bootstrap`**

```bash
#!/bin/bash

export SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

##
## Configuration Variables
##

config ()
{
    # A whitespace-separated list of executables that must be present and locatable.
    # These will each be installed through Homebrew if not found.
    : ${REQUIRED_TOOLS="cmake libtool autoconf automake pkg-config"}

    export REQUIRED_TOOLS
}

##
## Bootstrap Process
##

main ()
{
    config

    local submodules=$(git submodule status)
    local result=$?

    if [ "$result" -ne "0" ]
    then
        exit $result
    fi

    if [ -n "$submodules" ]
    then
        echo "*** Updating submodules..."
        update_submodules
    fi

    if [ -n "$REQUIRED_TOOLS" ]
    then
        echo "*** Checking dependencies..."
        check_deps
    fi
}

check_deps ()
{
    # Check if Homebrew is installed
    which -s brew
    local result=$?

    if [ "$result" -ne "0" ]
    then
        echo
        echo "Homebrew is not installed (https://brew.sh). Please install it, or manually ensure the following tools are installed:"
        echo "  $REQUIRED_TOOLS"
        echo
        exit $result
    fi

    # Ensure that we have libgit2/libssh2's build-time dependencies installed.
    installed=`brew list --formula`

    for tool in $REQUIRED_TOOLS
    do
        # Skip packages that are already installed.
        echo "$installed" | grep -q "$tool" && code=$? || code=$?

        if [ "$code" -eq "0" ]
        then
            echo "*** $tool is available"
            continue
        elif [ "$code" -ne "1" ]
        then
            exit $code
        fi

        echo "*** Installing $tool with Homebrew..."
        brew install "$tool"
    done
}

bootstrap_submodule ()
{
    local bootstrap="script/bootstrap"

    if [ -e "$bootstrap" ]
    then
        echo "*** Bootstrapping $name..."
        "$bootstrap" >/dev/null
    else
        update_submodules
    fi
}

update_submodules ()
{
    git submodule sync --quiet && \
        git submodule update --init && \
        git submodule foreach --quiet bootstrap_submodule
}

export -f bootstrap_submodule
export -f update_submodules

main
```

Changes from the original: `libssh2` removed from `REQUIRED_TOOLS` (no longer installed via Homebrew — Task 4 builds it from the submodule); the entire `brew_prefix`/`expected_prefix=/usr/local`/`sudo mkdir`/`sudo ln -s` block is deleted; the Homebrew-not-installed error message no longer tells the user to symlink libssh2 files under `/usr/local`.

- [ ] **Step 2: Run it and confirm it completes without `sudo` prompts**

```bash
script/bootstrap
```
Expected: exits 0, installs any missing `cmake`/`libtool`/`autoconf`/`automake`/`pkg-config` formulae, prints no `sudo` invocation, and does not touch `/usr/local`.

- [ ] **Step 3: Commit**

```bash
git add script/bootstrap
git commit -m "Drop /usr/local Homebrew-prefix hardcoding and libssh2 Homebrew dependency from bootstrap"
```

---

### Task 3: Add `script/update_mbedtls`

**Files:**
- Create: `script/update_mbedtls`

**Interfaces:**
- Consumes: `External/mbedtls` submodule checkout (Task 1), `brew`-installed `cmake` (Task 2).
- Produces: `External/build/lib/libmbedtls.a`, `External/build/lib/libmbedcrypto.a`, `External/build/lib/libmbedx509.a`, headers under `External/build/include/mbedtls` and `External/build/include/psa` — consumed by Task 4's libssh2 build (via `CMAKE_PREFIX_PATH`) and Task 7's Xcode aggregate target wiring.

- [ ] **Step 1: Create the script**

```sh
#!/bin/sh

set -e

ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd)
EXTERNAL_BUILD_PATH="${ROOT_PATH}/External/build"
PATH="$(brew --prefix)/bin:$PATH"

if [ "${EXTERNAL_BUILD_PATH}/lib/libmbedcrypto.a" -nt "${ROOT_PATH}/External/mbedtls" ]
then
    echo "No update needed."
    exit 0
fi

cd "${ROOT_PATH}/External/mbedtls"

if [ -d "build" ]; then
    rm -rf "build"
fi

mkdir build
cd build

cmake -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_PROGRAMS:BOOL=OFF \
    -DENABLE_TESTING:BOOL=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY:BOOL=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY:BOOL=ON \
    -DCMAKE_INSTALL_PREFIX="${EXTERNAL_BUILD_PATH}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    ..
cmake --build . --target install

echo "mbedTLS has been updated."
```

Make it executable: `chmod +x script/update_mbedtls`.

- [ ] **Step 2: Run it directly and confirm the expected artifacts appear**

```bash
script/update_mbedtls
ls External/build/lib/libmbedtls.a External/build/lib/libmbedcrypto.a External/build/lib/libmbedx509.a
ls External/build/include/mbedtls/version.h
file External/build/lib/libmbedcrypto.a
```
Expected: all three `.a` files and the header exist; `file` reports an arm64 Mach-O object archive (via `lipo -info` or `file` on an extracted `.o`, since `file` on a `.a` mostly reports "current ar archive" — the concrete architecture check is `lipo -info External/build/lib/libmbedcrypto.a` reporting `Non-fat file ... is architecture: arm64`).

- [ ] **Step 3: Commit**

```bash
git add script/update_mbedtls
git commit -m "Add script/update_mbedtls to build mbedTLS statically for arm64"
```

---

### Task 4: Add `script/update_libssh2` (macOS, CMake, mbedTLS backend)

**Files:**
- Create: `script/update_libssh2`

**Interfaces:**
- Consumes: `External/libssh2` submodule (Task 1), `External/build/{include,lib}` mbedTLS artifacts (Task 3, via `CMAKE_PREFIX_PATH`).
- Produces: `External/build/lib/libssh2.a`, headers under `External/build/include/libssh2*.h` — consumed by Task 5's libgit2 build (via `CMAKE_PREFIX_PATH`) and Task 7's Xcode wiring.

**Context:** There was no macOS `update_libssh2` before — macOS relied on Homebrew's `libssh2` formula (an OpenSSL-linked build), reached via the `/usr/local` symlink hack removed in Task 2. This is genuinely new, not a rewrite of an existing script. libgit2's own `SelectSSH.cmake` (verified against the real 1.9.7 source) first tries `pkg-config`, then falls back to `find_package(LibSSH2)`, which resolves via `CMAKE_PREFIX_PATH` — the shared `External/build` prefix used here satisfies that fallback automatically.

- [ ] **Step 1: Create the script**

```sh
#!/bin/sh

set -e

ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd)
EXTERNAL_BUILD_PATH="${ROOT_PATH}/External/build"
PATH="$(brew --prefix)/bin:$PATH"

if [ "${EXTERNAL_BUILD_PATH}/lib/libssh2.a" -nt "${ROOT_PATH}/External/libssh2" ]
then
    echo "No update needed."
    exit 0
fi

cd "${ROOT_PATH}/External/libssh2"

if [ -d "build" ]; then
    rm -rf "build"
fi

mkdir build
cd build

cmake -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_STATIC_LIBS:BOOL=ON \
    -DBUILD_EXAMPLES:BOOL=OFF \
    -DBUILD_TESTING:BOOL=OFF \
    -DCRYPTO_BACKEND=mbedTLS \
    -DCMAKE_PREFIX_PATH="${EXTERNAL_BUILD_PATH}" \
    -DCMAKE_INSTALL_PREFIX="${EXTERNAL_BUILD_PATH}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    ..
cmake --build . --target install

echo "libssh2 has been updated."
```

Make it executable: `chmod +x script/update_libssh2`.

- [ ] **Step 2: Run it (after Task 3 has produced mbedTLS artifacts) and confirm output**

```bash
script/update_mbedtls   # if not already run this session
script/update_libssh2
ls External/build/lib/libssh2.a External/build/include/libssh2.h
lipo -info External/build/lib/libssh2.a
```
Expected: `libssh2.a` and headers exist; `lipo -info` reports `architecture: arm64`; the CMake configure log (visible in the script's own stdout) shows `Crypto Backend: mbedTLS`, confirming it picked up mbedTLS rather than falling back to OpenSSL auto-detection.

- [ ] **Step 3: Commit**

```bash
git add script/update_libssh2
git commit -m "Add script/update_libssh2 to build libssh2 for arm64 macOS against mbedTLS"
```

---

### Task 5: Rewrite `script/update_libgit2` for arm64/Secure Transport/vendored libssh2

**Files:**
- Modify: `script/update_libgit2`

**Interfaces:**
- Consumes: `External/libgit2` submodule (Task 1), `External/build/{include,lib}/libssh2*` (Task 4, via `CMAKE_PREFIX_PATH`), system Secure Transport (no build step).
- Produces: `External/libgit2-mac.a` — consumed by Task 7/8's Xcode wiring (`-force_load External/libgit2-mac.a`, unchanged path from before).

**Context:** Flag names verified against the real `v1.9.7` `CMakeLists.txt`/`cmake/SelectSSH.cmake`/`cmake/SelectHTTPSBackend.cmake`, not assumed: `THREADSAFE` and `BUILD_CLAR` (used by the old script) no longer exist — replaced by `USE_THREADS` (defaults ON, no need to set) and `BUILD_TESTS` (defaults ON, must be turned off). `BUILD_CLI` is new in the 1.x line and defaults ON; turn it off since only the library is needed. `USE_SSH=libssh2` and `USE_HTTPS=SecureTransport` are the exact accepted values per the CMake option help text.

- [ ] **Step 1: Rewrite the script**

```sh
#!/bin/sh

set -e

ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd)
EXTERNAL_BUILD_PATH="${ROOT_PATH}/External/build"
PATH="$(brew --prefix)/bin:$PATH"

if [ "External/libgit2-mac.a" -nt "External/libgit2" ]
then
    echo "No update needed."
    exit 0
fi

cd "External/libgit2"

if [ -d "build" ]; then
    rm -rf "build"
fi

mkdir build
cd build

cmake -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_TESTS:BOOL=OFF \
    -DBUILD_CLI:BOOL=OFF \
    -DUSE_SSH=libssh2 \
    -DUSE_HTTPS=SecureTransport \
    -DCMAKE_PREFIX_PATH="${EXTERNAL_BUILD_PATH}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    ..
cmake --build .

product="libgit2.a"
install_path="../../"
if [ "libgit2.a" -nt "${install_path}/libgit2-mac.a" ]; then
    cp -v "libgit2.a" "${install_path}/libgit2-mac.a"
fi

echo "libgit2 has been updated."
```

- [ ] **Step 2: Run it (after Tasks 3–4 have produced mbedTLS/libssh2 artifacts) and confirm the feature flags took**

```bash
script/update_libgit2
lipo -info External/libgit2-mac.a
grep -c "SSH: " External/libgit2/build/CMakeCache.txt 2>/dev/null || true
```
Expected: `External/libgit2-mac.a` exists and is `arm64`. Re-run the CMake configure step manually if needed and confirm the printed feature summary includes `SSH: ...libssh2...` and `HTTPS: ...SecureTransport...` (libgit2's CMake prints an `add_feature_info` summary at configure time — this is the direct evidence the right backends were selected, not just that the build didn't error).

- [ ] **Step 3: Commit**

```bash
git add script/update_libgit2
git commit -m "Rebuild libgit2 for arm64 macOS with Secure Transport HTTPS and vendored libssh2 SSH"
```

---

### Task 6: Remove iOS-only and stale build scripts

**Files:**
- Delete: `script/update_libgit2_ios`, `script/update_libssh2_ios`, `script/update_libssl_ios`, `script/ios_build_functions.sh`, `script/xcode_functions.sh`, `script/pkg-config-static`
- Modify: `script/clean_externals`
- Modify: `script/cibuild`

**Interfaces:**
- Consumes: nothing new.
- Produces: a `script/` directory with no dangling references to deleted iOS scripts or stale output paths — checked by Task 7's Xcode target removal (which deletes the Run Script build phases that invoked these files).

- [ ] **Step 1: Delete the iOS-only scripts**

```bash
git rm script/update_libgit2_ios script/update_libssh2_ios script/update_libssl_ios script/ios_build_functions.sh script/xcode_functions.sh script/pkg-config-static
```

- [ ] **Step 2: Rewrite `script/clean_externals` to match the real current output paths**

The existing script's path list (`External/libgit2.a`, `External/libgit2-ios/...`, `External/libssh2-ios/...`, `External/ios-openssl/...`) doesn't match any path any current script actually produces — it's stale leftover from an older layout. Replace with the paths this plan's scripts actually write:

```bash
#!/bin/bash -ex

#
# clean_externals
# ObjectiveGit
#
# Removes the outputs from the various static library targets.
# Necessary when switching architectures as Xcode does not clean
# these for you.
#

libraries=(
    External/libgit2-mac.a
    External/build
)

rm -vrf "${libraries[@]}"
```

- [ ] **Step 3: Trim `script/cibuild`'s dead iOS branch**

The iOS branch invokes `xcodebuild ... -scheme "ObjectiveGit iOS" ...`, a scheme Task 7 deletes; `-scheme "ObjectiveGit Mac"` is what's left. CI itself stays out of scope (this is dead-reference cleanup tied to the target removal, not new CI work):

```bash
#!/bin/bash -ex
#
# script/cibuild
# ObjectiveGit
#
# Executes the build and runs tests for macOS.
#
# Dependent tools & scripts:
# - script/bootstrap
# - [xcodebuild](https://developer.apple.com/library/mac/documentation/Darwin/Reference/ManPages/man1/xcodebuild.1.html)
#
# Environment Variables:
# - SCHEME: specifies which Xcode scheme to build. Set to:
#   - ObjectiveGit Mac

if [ -z "$SCHEME" ]; then
  echo "The SCHEME environment variable is empty. Please set this to:"
  echo "- ObjectiveGit Mac"
  exit 1
fi

##
## Configuration Variables
##

set -o pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
XCWORKSPACE="ObjectiveGitFramework.xcworkspace"
XCODE_OPTIONS=(RUN_CLANG_STATIC_ANALYZER=NO ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO)

##
## Build Process
##

echo "*** Bootstrapping..."
"$SCRIPT_DIR/bootstrap"

echo "*** Building and testing $SCHEME..."
echo

xcodebuild -workspace "$XCWORKSPACE" \
  -scheme "$SCHEME" \
  "${XCODE_OPTIONS[@]}" \
  build test
```

(Also dropped the dead `TRAVIS`/`xcpretty-travis-formatter` branch — Travis is defunct and out of scope per the design spec; this script is CI-adjacent housekeeping tied directly to the iOS scheme's removal, not new CI infrastructure.)

- [ ] **Step 4: Verify no remaining references to deleted scripts**

```bash
grep -rl "update_libgit2_ios\|update_libssh2_ios\|update_libssl_ios\|ios_build_functions\|xcode_functions.sh\|pkg-config-static" --include="*.sh" --include="cibuild" --include="bootstrap" script/ || echo "clean"
```
Expected: `clean` (Xcode project references to these are removed separately in Task 7 — this check is scoped to `script/` itself).

- [ ] **Step 5: Commit**

```bash
git add -A script/
git commit -m "Remove iOS-only build scripts and fix stale clean_externals/cibuild references"
```

---

### Task 7: Remove iOS targets/aggregates/scheme; add mbedTLS/libssh2 aggregate targets

**Files:**
- Modify: `ObjectiveGitFramework.xcodeproj/project.pbxproj`
- Delete: `ObjectiveGitFramework.xcodeproj/xcshareddata/xcschemes/ObjectiveGit iOS.xcscheme`

**Interfaces:**
- Consumes: `script/update_mbedtls` (Task 3), `script/update_libssh2` (Task 4), `script/update_libgit2` (Task 5).
- Produces: an `ObjectiveGitFramework.xcodeproj` with exactly two native targets (`ObjectiveGit-Mac`, `ObjectiveGit-MacTests`) and three aggregate targets (`mbedtls` → `libssh2` → `libgit2`, dependency order) — consumed by Task 8 (build settings on the surviving targets) and Task 9 (xcframework packaging references the `ObjectiveGit Mac` scheme).

**Context (from project audit):** Today there are 4 native targets (`ObjectiveGit-Mac`, `ObjectiveGit-MacTests`, `ObjectiveGit-iOS`, `ObjectiveGit-iOSTests`) and 4 aggregate targets (`OpenSSL-iOS`, `libssh2-iOS` [depends on `OpenSSL-iOS`], `libgit2` [mac, no deps today], `libgit2-iOS` [depends on `libssh2-iOS`]). `ObjectiveGit-Mac` already depends on the `libgit2` aggregate target. This task removes the iOS side, adds two new aggregate targets that mirror the removed `OpenSSL-iOS`→`libssh2-iOS` dependency shape (just mbedTLS→libssh2 instead of OpenSSL→libssh2), and rewires `libgit2`'s Run Script phase and dependency to point at the new chain. Do this in Xcode's GUI (Project Navigator → target list) rather than hand-editing `project.pbxproj`'s UUID-linked structure — the pbxproj format is fragile to hand edits at this scale (per the flowdeck skill: don't parse/edit Xcode project files manually with text tools).

- [ ] **Step 1: Open the project and delete the iOS native targets**

In Xcode, open `ObjectiveGitFramework.xcodeproj`. In the project editor's target list, select `ObjectiveGit-iOS` and `ObjectiveGit-iOSTests`, right-click → Delete → "Move to Trash" is not needed, just remove from the project (delete only the target, not backing files — these targets don't own unique source files, everything is shared with the Mac target).

- [ ] **Step 2: Delete the iOS-only aggregate targets**

Delete `OpenSSL-iOS` and `libssh2-iOS` aggregate targets entirely (they only fed the now-deleted `libgit2-iOS` target). Delete `libgit2-iOS` as well.

- [ ] **Step 3: Delete the iOS scheme**

```bash
git rm "ObjectiveGitFramework.xcodeproj/xcshareddata/xcschemes/ObjectiveGit iOS.xcscheme"
```

- [ ] **Step 4: Add the `mbedtls` aggregate target**

New Aggregate target named `mbedtls`, no dependencies. Add one Run Script build phase:
```
shellScript = script/update_mbedtls
```
Set the phase's Input Files to `$(SRCROOT)/External/mbedtls/CMakeLists.txt` and Output Files to `$(SRCROOT)/External/build/lib/libmbedcrypto.a` (the existing iOS scripts left `inputPaths`/`outputPaths` empty, which the build-scripts audit flagged as a correctness gap for Xcode's incremental build graph — fix it here rather than repeating the gap).

- [ ] **Step 5: Add the `libssh2` aggregate target**

New Aggregate target named `libssh2`, with a target dependency on `mbedtls` (Xcode: target's "General" tab → "Dependencies" → add `mbedtls`). One Run Script build phase:
```
shellScript = script/update_libssh2
```
Input Files: `$(SRCROOT)/External/libssh2/CMakeLists.txt`. Output Files: `$(SRCROOT)/External/build/lib/libssh2.a`.

- [ ] **Step 6: Rewire the existing `libgit2` aggregate target**

Add a target dependency on `libssh2` (so mbedtls → libssh2 → libgit2 build order is enforced). Its Run Script phase already points at `script/update_libgit2` (unchanged path) — set Input Files to `$(SRCROOT)/External/libgit2/CMakeLists.txt $(SRCROOT)/External/build/lib/libssh2.a` and Output Files to `$(SRCROOT)/External/libgit2-mac.a`.

- [ ] **Step 7: Verify target/scheme state**

Use the flowdeck skill to list the project's targets and schemes.
Expected: native targets are exactly `ObjectiveGit-Mac` and `ObjectiveGit-MacTests`; aggregate targets are exactly `mbedtls`, `libssh2`, `libgit2`; only the `ObjectiveGit Mac` scheme remains.

- [ ] **Step 8: Commit**

```bash
git add -A ObjectiveGitFramework.xcodeproj
git commit -m "Remove iOS targets/scheme, add mbedtls and libssh2 aggregate targets"
```

---

### Task 8: Xcode build settings — deployment target, arm64 pin, search paths, link flags

**Files:**
- Modify: `ObjectiveGitFramework.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 7's surviving targets; `External/build/{include,lib}` layout from Tasks 3–5.
- Produces: an `ObjectiveGit-Mac` target that links Secure Transport + the new static libs instead of Homebrew OpenSSL/libssh2 — consumed by Task 14 (first full compile pass).

**Context (from project audit):** deployment targets, `HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`, and `OTHER_LDFLAGS` are all set directly in `project.pbxproj`'s `XCBuildConfiguration` blocks (not in the vendored `xcconfigs` submodule), across 4 configs each (Debug/Release/Test/Profile) at both project level and `ObjectiveGit-Mac` target level. `ARCHS`/`VALID_ARCHS` are currently unset anywhere (net-new settings, not edits). Linking Secure Transport requires the consuming target (not just libgit2's own build) to link `Security.framework`, since libgit2 ships as a static archive whose Secure Transport calls must be resolved at the final link.

- [ ] **Step 1: Set deployment target and architecture pin (project-level, all 4 configs)**

In Xcode's Build Settings for the project (not a target), for Debug/Release/Test/Profile:
- `MACOSX_DEPLOYMENT_TARGET` = `15.0` (was `10.10`)
- Remove `IPHONEOS_DEPLOYMENT_TARGET` (was `9.3` — no iOS target left to need it)
- Add `ARCHS` = `arm64` (new setting)
- Add `VALID_ARCHS` = `arm64` (new setting)
- Remove `TARGETED_DEVICE_FAMILY` (iOS-only setting)

- [ ] **Step 2: Fix project-level `HEADER_SEARCH_PATHS`/`LIBRARY_SEARCH_PATHS`**

Project-level `HEADER_SEARCH_PATHS` (all 4 configs) becomes:
```
HEADER_SEARCH_PATHS = (
    External/libgit2/include,
);
```
(drops `/usr/local/include` — nothing needs it anymore).

Project-level `LIBRARY_SEARCH_PATHS` currently reads `(., External)` in the iOS-flavored configs — leave the Mac-relevant entries (`.`, `External`) as-is; they're harmless and some scripts still resolve relative to them.

- [ ] **Step 3: Fix `ObjectiveGit-Mac` target-level `HEADER_SEARCH_PATHS`**

For all 4 configs:
```
HEADER_SEARCH_PATHS = (
    "$(inherited)",
    External/build/include,
);
```
(unchanged path — this already covered `External/build/include` for the old iOS-only libssh2/OpenSSL install prefix; it now also picks up the mbedTLS/libssh2 headers Tasks 3–4 install there, no edit needed to the path itself, just confirm it wasn't accidentally deleted along with other iOS-tagged settings.) Also remove the stray duplicate `HEADER_SEARCH_PATHS = ("$(inherited)", External/build/include);` / `LIBRARY_SEARCH_PATHS = "$(PROJECT_DIR)/External/build/lib";` / `OTHER_LDFLAGS = "-all_load";` config blocks the audit found (lines noted as an "alternate" duplicate XCBuildConfiguration in the project audit) — Xcode's GUI editing will surface these as a second set of rows if they're genuinely duplicate configs; consolidate to one set of values per config.

- [ ] **Step 4: Fix `ObjectiveGit-Mac` target-level `LIBRARY_SEARCH_PATHS`**

For all 4 configs:
```
LIBRARY_SEARCH_PATHS = (
    "$(inherited)",
    "$(PROJECT_DIR)/External/build/lib",
    "$(PROJECT_DIR)/External",
);
```
(drops `/usr/local/opt/openssl/lib`).

- [ ] **Step 5: Fix `ObjectiveGit-Mac` target-level `OTHER_LDFLAGS`**

For all 4 configs:
```
OTHER_LDFLAGS = (
    "-force_load",
    "External/libgit2-mac.a",
    "$(PROJECT_DIR)/External/build/lib/libssh2.a",
    "$(PROJECT_DIR)/External/build/lib/libmbedtls.a",
    "$(PROJECT_DIR)/External/build/lib/libmbedcrypto.a",
    "$(PROJECT_DIR)/External/build/lib/libmbedx509.a",
    "-lcurl",
    "-framework",
    "Security",
);
```
(drops `/usr/local/lib/libssh2.a`, `-lcrypto`, `-lssl`; adds the vendored libssh2/mbedTLS static libs by path and `-framework Security` for Secure Transport's link-time symbols; keeps `-lcurl` since libgit2 can still use system curl for plain-HTTP transport regardless of the HTTPS/TLS backend).

- [ ] **Step 6: Remove Carthage `FRAMEWORK_SEARCH_PATHS` for the iOS test target (now deleted) — leave the Mac one for Task 15**

The iOS test target's `FRAMEWORK_SEARCH_PATHS` (`$(PROJECT_DIR)/Carthage/Build/iOS`) is deleted along with the target in Task 7. Leave `ObjectiveGit-MacTests`'s `$(PROJECT_DIR)/Carthage/Build/Mac` entry alone for now — Task 15 removes it as part of the SPM migration.

- [ ] **Step 7: Build and verify settings took effect**

Use the flowdeck skill to build the `ObjectiveGit Mac` scheme (this will fail with compiler errors until Tasks 10–14 apply the source-level fixes — that's expected here; the goal of this step is to confirm the *build settings* are correct, i.e. the failure is a compile error inside `ObjectiveGit/*.m`, not a "file not found"/linker "library not found" error). Confirm via the build log that `External/libgit2-mac.a`, `External/build/lib/libssh2.a`, and the mbedtls libs are found by the linker (no `ld: library not found for -lssh2` or similar), and that `MACOSX_DEPLOYMENT_TARGET`/arch show as `15.0`/`arm64` in the build log's compile invocation lines.

- [ ] **Step 8: Commit**

```bash
git add ObjectiveGitFramework.xcodeproj
git commit -m "Raise deployment target to macOS 15, pin arm64, relink against vendored libssh2/mbedTLS + Secure Transport"
```

---

### Task 9: Add `.xcframework` packaging

**Files:**
- Create: `script/create_xcframework`

**Interfaces:**
- Consumes: a buildable `ObjectiveGit Mac` scheme (Task 8 settings + Tasks 10–14 source fixes).
- Produces: `build/ObjectiveGit.xcframework` — the plan's final deliverable artifact.

- [ ] **Step 1: Create the script**

```sh
#!/bin/sh

set -e

ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd)
BUILD_PATH="${ROOT_PATH}/build"
ARCHIVE_PATH="${BUILD_PATH}/ObjectiveGit-macOS.xcarchive"
XCFRAMEWORK_PATH="${BUILD_PATH}/ObjectiveGit.xcframework"

rm -rf "${ARCHIVE_PATH}" "${XCFRAMEWORK_PATH}"

xcodebuild archive \
    -project "${ROOT_PATH}/ObjectiveGitFramework.xcodeproj" \
    -scheme "ObjectiveGit Mac" \
    -archivePath "${ARCHIVE_PATH}" \
    -destination "generic/platform=macOS" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES

xcodebuild -create-xcframework \
    -framework "${ARCHIVE_PATH}/Products/Library/Frameworks/ObjectiveGit.framework" \
    -output "${XCFRAMEWORK_PATH}"

echo "Created ${XCFRAMEWORK_PATH}"
```

Make it executable: `chmod +x script/create_xcframework`. (This script itself calls `xcodebuild` directly — see Global Constraints: that rule governs the plan *executor's* verification actions, not the project's own shipped packaging tooling, which has no flowdeck equivalent for "create an xcframework".)

- [ ] **Step 2: Run it (once Tasks 10–14 make the scheme buildable) and verify**

```bash
script/create_xcframework
ls build/ObjectiveGit.xcframework/Info.plist
plutil -p build/ObjectiveGit.xcframework/Info.plist
```
Expected: exit 0; `Info.plist` lists one `macos-arm64` library slice pointing at `ObjectiveGit.framework`.

- [ ] **Step 3: Commit**

```bash
git add script/create_xcframework
git commit -m "Add script/create_xcframework for packaging the macOS build"
```

---

### Task 10: Apply the `git_cred*` → `git_credential*` rename

**Files:**
- Modify: `ObjectiveGit/GTCredential.h`
- Modify: `ObjectiveGit/GTCredential.m`
- Modify: `ObjectiveGit/GTCredential+Private.h`
- Test: `ObjectiveGitTests/GTCredential+Private.h` usage is exercised indirectly by any spec that authenticates — no dedicated `GTCredentialSpec.m` exists today, so this task adds a minimal one.

**Interfaces:**
- Consumes: libgit2 1.9.7 headers (`git2/credential.h` / `git2/transport.h`) from Task 1's submodule bump.
- Produces: `GTCredential`'s public API unchanged in shape (same method/selector names), only the underlying libgit2 C symbols change — consumed by `GTRepository.m`/`GTRepository+RemoteOperations.m`'s existing `GTCredentialAcquireCallback` usage (no changes needed there; confirmed by audit that no other file references `git_cred*` symbols directly).

- [ ] **Step 1: Write the pinning test for Review Focus item 1 (enum values survive the rename)**

Create `ObjectiveGitTests/GTCredentialSpec.m`:
```objc
//
//  GTCredentialSpec.m
//  ObjectiveGitFramework
//

@import Nimble;
@import Quick;

#import "GTCredential.h"
#import "git2/credential.h"

QuickSpecBegin(GTCredentialSpec)

describe(@"GTCredentialType", ^{
	it(@"maps to the same underlying libgit2 credential type values after the git_credential rename", ^{
		expect(@(GTCredentialTypeUserPassPlaintext)).to(equal(@(GIT_CREDENTIAL_USERPASS_PLAINTEXT)));
		expect(@(GTCredentialTypeSSHKey)).to(equal(@(GIT_CREDENTIAL_SSH_KEY)));
		expect(@(GTCredentialTypeSSHCustom)).to(equal(@(GIT_CREDENTIAL_SSH_CUSTOM)));
	});
});

describe(@"+credentialWithUserName:password:error:", ^{
	it(@"creates a plaintext credential", ^{
		NSError *error = nil;
		GTCredential *credential = [GTCredential credentialWithUserName:@"user" password:@"pass" error:&error];
		expect(credential).notTo(beNil());
		expect(error).to(beNil());
	});
});

QuickSpecEnd
```
This pins Review Focus item 1: if a future edit silently changes `GTCredentialType`'s raw values, or the rename is applied inconsistently between the header's enum and libgit2's real constants, this test fails immediately instead of surfacing as a confusing runtime auth failure later.

- [ ] **Step 2: Run it and confirm it fails to compile** (since `GIT_CREDENTIAL_*` don't exist until the rename lands, and `GTCredentialType` still maps to the old `GIT_CREDTYPE_*` names)

Use the flowdeck skill to run the `ObjectiveGit-MacTests` target's `GTCredentialSpec`.
Expected: build failure — `GIT_CREDENTIAL_USERPASS_PLAINTEXT`/etc. not found (they don't exist in libgit2 0.28's installed headers this project was last built against, and won't resolve at all until Task 1's libgit2 1.9.7 bump is compiled against, which happens together with this task).

- [ ] **Step 3: Apply the rename to `GTCredential.h`**

```objc
// was: /// See `git_credtype_t`.
/// See `git_credential_t`.
typedef NS_ENUM(NSInteger, GTCredentialType) {
	GTCredentialTypeUserPassPlaintext = GIT_CREDENTIAL_USERPASS_PLAINTEXT,
	GTCredentialTypeSSHKey = GIT_CREDENTIAL_SSH_KEY,
	GTCredentialTypeSSHCustom = GIT_CREDENTIAL_SSH_CUSTOM,
};
```
and:
```objc
// was: /// It acts as a wrapper around `git_cred` objects.
/// It acts as a wrapper around `git_credential` objects.
```
```objc
// was: /// The underlying `git_cred` object.
// was: - (git_cred *)git_cred __attribute__((objc_returns_inner_pointer));
/// The underlying `git_credential` object.
- (git_credential *)git_cred __attribute__((objc_returns_inner_pointer));
```
(The Objective-C selector name `git_cred` itself is unchanged — only the C type it returns changes — matching the audit's note that renaming the libgit2 type doesn't require renaming the ObjC accessor.)

- [ ] **Step 4: Apply the rename to `GTCredential.m`**

```objc
@interface GTCredential ()
@property (nonatomic, assign, readonly) git_credential *git_cred;
@end

@implementation GTCredential

+ (instancetype)credentialWithUserName:(NSString *)userName password:(NSString *)password error:(NSError **)error {
	git_credential *cred;
	int gitError = git_credential_userpass_plaintext_new(&cred, userName.UTF8String, password.UTF8String);
	if (gitError != GIT_OK) {
		if (error) *error = [NSError git_errorFor:gitError description:@"Failed to create credentials object" failureReason:@"There was an error creating a credential object for username %@.", userName];
		return nil;
	}

	return [[self alloc] initWithGitCred:cred];
}

+ (instancetype)credentialWithUserName:(NSString *)userName publicKeyURL:(NSURL *)publicKeyURL privateKeyURL:(NSURL *)privateKeyURL passphrase:(NSString *)passphrase error:(NSError **)error {
	NSParameterAssert(privateKeyURL != nil);
	NSString *publicKeyPath = publicKeyURL.filePathURL.path;
	NSString *privateKeyPath = privateKeyURL.filePathURL.path;
	NSAssert(privateKeyPath != nil, @"Invalid file URL passed: %@", privateKeyURL);

	git_credential *cred;
	int gitError = git_credential_ssh_key_new(&cred, userName.UTF8String, publicKeyPath.fileSystemRepresentation, privateKeyPath.fileSystemRepresentation, passphrase.UTF8String);
	if (gitError != GIT_OK) {
		if (error) *error = [NSError git_errorFor:gitError description:@"Failed to create credentials object" failureReason:@"There was an error creating a credential object for username %@ with the provided public/private key pair.\nPublic key: %@\nPrivate key: %@", userName, publicKeyURL, privateKeyURL];
		return nil;
	}

	return [[self alloc] initWithGitCred:cred];
}

+ (instancetype)credentialWithUserName:(NSString *)userName publicKeyString:(NSString *)publicKeyString privateKeyString:(NSString *)privateKeyString passphrase:(NSString *)passphrase error:(NSError **)error {
	NSParameterAssert(privateKeyString != nil);

	git_credential *cred;
	int gitError = git_credential_ssh_key_memory_new(&cred, userName.UTF8String, publicKeyString.UTF8String, privateKeyString.UTF8String, passphrase.UTF8String);
	if (gitError != GIT_OK) {
		if (error) *error = [NSError git_errorFor:gitError description:@"Failed to create credentials object" failureReason:@"There was an error creating a credential object for username %@ with the provided public/private key pair.\nPublic key: %@", userName, publicKeyString];
		return nil;
	}

	return [[self alloc] initWithGitCred:cred];
}

- (instancetype)initWithGitCred:(git_credential *)cred {
	NSParameterAssert(cred != nil);
	self = [self init];

	if (self == nil) return nil;

	_git_cred = cred;

	return self;
}

@end

int GTCredentialAcquireCallback(git_credential **git_cred, const char *url, const char *username_from_url, unsigned int allowed_types, void *payload) {
	NSCParameterAssert(git_cred != NULL);
	NSCParameterAssert(payload != NULL);

	GTCredentialAcquireCallbackInfo *info = payload;
	GTCredentialProvider *provider = info->credProvider;

	if (provider == nil) {
		git_error_set_str(GIT_EUSER, "No GTCredentialProvider set, but authentication was requested.");
		return GIT_ERROR;
	}

	NSString *URL = (url != NULL ? @(url) : @"");
	NSString *userName = (username_from_url != NULL ? @(username_from_url) : nil);

	GTCredential *cred = [provider credentialForType:(GTCredentialType)allowed_types URL:URL userName:userName];
	if (cred == nil) {
		git_error_set_str(GIT_EUSER, "GTCredentialProvider failed to provide credentials.");
		return GIT_ERROR;
	}

	*git_cred = cred.git_cred;
	return GIT_OK;
}
```

- [ ] **Step 5: Apply the rename to `GTCredential+Private.h`**

```objc
int GTCredentialAcquireCallback(git_credential **cred, const char *url, const char *username_from_url, unsigned int allowed_types, void *payload);
```
Also fix the stale doc-comment example referencing the removed `git_remote_set_cred_acquire_cb` API — replace it with a note that the `credentials` field of `git_fetch_options`/`git_clone_options`/`git_push_options` is where `GTCredentialAcquireCallback` actually gets wired up (matching how `GTRepository+RemoteOperations.m` already does it).

- [ ] **Step 6: Run the spec and confirm it passes**

Use the flowdeck skill to build and run `ObjectiveGit-MacTests`'s `GTCredentialSpec`.
Expected: PASS (this will only fully succeed once Task 14's full compile pass is green, since `GTCredential.m` alone compiling doesn't mean the whole test target links — treat a PASS here as provisional until Task 14; if it still doesn't compile due to unrelated errors elsewhere in the target, note that and continue to Task 11, returning to confirm this spec passes as part of Task 14's final green build).

- [ ] **Step 7: Commit**

```bash
git add ObjectiveGit/GTCredential.h ObjectiveGit/GTCredential.m ObjectiveGit/GTCredential+Private.h ObjectiveGitTests/GTCredentialSpec.m
git commit -m "Rename git_cred* to git_credential* for libgit2 1.9 compatibility"
```

---

### Task 11: Apply the `git_transfer_progress` → `git_indexer_progress` rename

**Files:**
- Modify: `ObjectiveGit/GTRepository.h`
- Modify: `ObjectiveGit/GTRepository.m`
- Modify: `ObjectiveGit/GTRepository+RemoteOperations.h`
- Modify: `ObjectiveGit/GTRepository+RemoteOperations.m`
- Modify: `ObjectiveGit/GTRepository+Merging.m`
- Modify: `ObjectiveGit/GTRepository+Pull.h`

**Interfaces:**
- Consumes: libgit2 1.9.7's `git2/indexer.h` (`git_indexer_progress`) from Task 1.
- Produces: no change to any ObjectiveGit-level type/selector name (`GTTransferProgressBlock`, `GTRemoteFetchTransferProgressBlock`, `transferProgressBlock:`, `progress:` stay as-is) — only the embedded libgit2 struct name changes, so no other file needs updating (confirmed by audit: every occurrence of `git_transfer_progress` in the codebase is confined to these six files/declarations).

**Context:** `GTRepository.h`'s `cloneFromURL:...transferProgressBlock:` declaration and `GTRepository.m`'s definition must change together (same exact parameter type) or the method's declaration and definition diverge and the compiler flags a mismatch.

- [ ] **Step 1: `ObjectiveGit/GTRepository.h`**

```objc
+ (instancetype _Nullable)cloneFromURL:(NSURL *)originURL toWorkingDirectory:(NSURL *)workdirURL options:(NSDictionary * _Nullable)options error:(NSError **)error transferProgressBlock:(void (^ _Nullable)(const git_indexer_progress *, BOOL *stop))transferProgressBlock;
```

- [ ] **Step 2: `ObjectiveGit/GTRepository.m`**

```objc
typedef void(^GTTransferProgressBlock)(const git_indexer_progress *progress, BOOL *stop);

static int transferProgressCallback(const git_indexer_progress *progress, void *payload) {
	// body unchanged
}

+ (instancetype _Nullable)cloneFromURL:(NSURL *)originURL toWorkingDirectory:(NSURL *)workdirURL options:(NSDictionary * _Nullable)options error:(NSError **)error transferProgressBlock:(void (^ _Nullable)(const git_indexer_progress *, BOOL *stop))transferProgressBlock {
	// body unchanged
}
```

- [ ] **Step 3: `ObjectiveGit/GTRepository+RemoteOperations.h`**

```objc
- (BOOL)fetchRemote:(GTRemote *)remote withOptions:(NSDictionary * _Nullable)options error:(NSError **)error progress:(void (^ _Nullable)(const git_indexer_progress *stats, BOOL *stop))progressBlock;
```

- [ ] **Step 4: `ObjectiveGit/GTRepository+RemoteOperations.m`**

```objc
typedef void (^GTRemoteFetchTransferProgressBlock)(const git_indexer_progress *stats, BOOL *stop);

int GTRemoteFetchTransferProgressCallback(const git_indexer_progress *stats, void *payload) {
	// body unchanged
}
```

- [ ] **Step 5: `ObjectiveGit/GTRepository+Merging.m`**

```objc
typedef void (^GTRemoteFetchTransferProgressBlock)(const git_indexer_progress *stats, BOOL *stop);
```

- [ ] **Step 6: `ObjectiveGit/GTRepository+Pull.h`**

```objc
typedef void (^GTRemoteFetchTransferProgressBlock)(const git_indexer_progress *progress, BOOL *stop);
```

- [ ] **Step 7: Verify no `git_transfer_progress` occurrences remain**

```bash
grep -rn "git_transfer_progress" ObjectiveGit/
```
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add ObjectiveGit/GTRepository.h ObjectiveGit/GTRepository.m ObjectiveGit/GTRepository+RemoteOperations.h ObjectiveGit/GTRepository+RemoteOperations.m ObjectiveGit/GTRepository+Merging.m ObjectiveGit/GTRepository+Pull.h
git commit -m "Rename git_transfer_progress to git_indexer_progress for libgit2 1.9 compatibility"
```

---

### Task 12: Fix `git_buf` usage for libgit2 1.9's output-only buffer API

**Files:**
- Modify: `ObjectiveGit/Categories/NSData+Git.m`, `ObjectiveGit/Categories/NSData+Git.h`
- Modify: `ObjectiveGit/GTFilter.m`
- Modify: `ObjectiveGit/GTFilterList.m`
- Modify: `ObjectiveGit/GTConfiguration.m`
- Modify: `ObjectiveGit/GTBlob.m`
- Modify: `ObjectiveGit/GTRepository.m`
- Modify: `ObjectiveGit/GTNote.m`
- Modify: `ObjectiveGit/GTBranch.m`
- Modify: `ObjectiveGit/GTDiffPatch.m`
- Test: `ObjectiveGitTests/GTFilterSpec.m` (extend), `ObjectiveGitTests/NSDataGitSpec.m` (extend)

**Interfaces:**
- Consumes: libgit2 1.9.7's `git2/buffer.h` (verified directly against the real header during plan research: `git_buf` is now `{ char *ptr; size_t reserved; size_t size; }`, `GIT_BUF_INIT` is the only init macro — `GIT_BUF_INIT_CONST` no longer exists — and `git_buf_dispose` is the only free function — `git_buf_free`/`git_buf_grow`/`git_buf_set`/`git_buf_contains_nul`/`git_buf_is_binary` are not declared in the public header).
- Produces: binary-safe data round-tripping through every listed call site — consumed by every spec that reads blob/note/filter content (no new public API surface).

**Context:** This is the plan's confirmed-but-unenumerated risk pocket (see Global Constraints). `git_buf` in 0.28 could be used as an *input* buffer (a caller pre-fills `ptr`/`asize`/`size` and passes it in) via `GIT_BUF_INIT_CONST`; in 1.x, `git_buf` is output-only everywhere in the public API, so any call site that constructed one to *send data into* libgit2 needs the modern non-`git_buf` entry point for that specific operation instead. Because each of the nine files above calls a different libgit2 function, this task's method is the same one the spec prescribes for the two named renames: build against the real 1.9.7 headers, let the compiler enumerate every broken call site, and fix each one by reading that specific function's current signature in the vendored `External/libgit2/include` tree (not by guessing from memory) — the two `GIT_BUF_INIT_CONST` sites are the ones already confirmed broken; the `git_buf_free`/`git_buf_grow`/`git_buf_set` sites are confirmed broken by the same header diff; whether the other `git_buf`-adjacent lines in `GTConfiguration.m`/`GTBlob.m`/`GTFilterList.m`/`GTNote.m`/`GTBranch.m`/`GTDiffPatch.m` need code changes (vs. just a `git_buf_free`→`git_buf_dispose` rename) depends on what the compiler surfaces.

- [ ] **Step 1: Build and capture every `git_buf`-related compiler error**

Use the flowdeck skill to build `ObjectiveGit-Mac`. Collect every error whose message references `git_buf`, `GIT_BUF_INIT_CONST`, `git_buf_free`, `git_buf_grow`, `git_buf_set`, `git_buf_contains_nul`, or `git_buf_is_binary`.

- [ ] **Step 2: For each `git_buf_free` call site, do the mechanical rename**

```bash
grep -rln "git_buf_free" ObjectiveGit/
```
Replace each `git_buf_free(...)` with `git_buf_dispose(...)` (same signature, confirmed by the header: `GIT_EXTERN(void) git_buf_dispose(git_buf *buffer);`).

- [ ] **Step 3: For each `GIT_BUF_INIT_CONST` call site (confirmed in `NSData+Git.m`), replace the input-buffer pattern**

Read the current signature of whatever libgit2 function that `git_buf` was being constructed to feed (check `External/libgit2/include/git2/*.h` for the actual call, e.g. a filter or blob-content API) and replace the `GIT_BUF_INIT_CONST`-based construction with a direct `const char *`/`size_t` pair or whatever the 1.9 signature now takes — libgit2 1.x systematically replaced "pass a pre-filled `git_buf` in" parameters with plain pointer+length pairs for exactly this reason.

- [ ] **Step 4: For `git_buf_grow`/`git_buf_set` call sites (in `GTFilter.m`), find the 1.9 equivalent**

These were used to build up a `git_buf` incrementally as an output buffer being reused across calls. Check `External/libgit2/include/git2/buffer.h` and `git2/sys/filter.h` for the current pattern — libgit2 1.x filter APIs generally hand you a fully-populated output `git_buf` per call rather than expecting you to pre-grow one, so the fix is likely deleting the pre-grow step rather than finding a renamed equivalent; confirm against the real header rather than assuming.

- [ ] **Step 5: Write/extend a binary round-trip test pinning Review Focus item 2**

Extend `ObjectiveGitTests/GTFilterSpec.m` with a case that pushes non-UTF8, NUL-containing binary data through the filter list and asserts byte-for-byte equality on the way out:
```objc
it(@"round-trips binary data containing embedded NUL bytes without truncation", ^{
	uint8_t rawBytes[] = { 0x00, 0xFF, 0x00, 0x41, 0x00, 0x42 };
	NSData *original = [NSData dataWithBytes:rawBytes length:sizeof(rawBytes)];

	NSError *error = nil;
	NSData *roundTripped = [self.filterList applyToData:original error:&error];

	expect(error).to(beNil());
	expect(roundTripped).to(equal(original));
});
```
(Adjust the exact `GTFilterList` invocation to match whatever method the file already uses to apply filters to in-memory data — the point of this step is the assertion, not inventing a new entry point; use the existing spec's setup/helpers.)

- [ ] **Step 6: Run the full build + the new/extended specs**

Use the flowdeck skill to build `ObjectiveGit-Mac` and run `GTFilterSpec`/`NSDataGitSpec`.
Expected: build succeeds with no `git_buf`-related errors; the binary round-trip test passes.

- [ ] **Step 7: Commit**

```bash
git add ObjectiveGit/Categories/NSData+Git.m ObjectiveGit/Categories/NSData+Git.h ObjectiveGit/GTFilter.m ObjectiveGit/GTFilterList.m ObjectiveGit/GTConfiguration.m ObjectiveGit/GTBlob.m ObjectiveGit/GTRepository.m ObjectiveGit/GTNote.m ObjectiveGit/GTBranch.m ObjectiveGit/GTDiffPatch.m ObjectiveGitTests/GTFilterSpec.m
git commit -m "Adapt git_buf usage to libgit2 1.9's output-only buffer API"
```

---

### Task 13: Handle `git_submodule_set_ignore` deprecation

**Files:**
- Modify: `ObjectiveGit/GTSubmodule.m`
- Modify: `ObjectiveGit/GTSubmodule.h` (only if the method's contract needs to change — see Step 2)
- Test: `ObjectiveGitTests/GTSubmoduleSpec.m` (extend)

**Interfaces:**
- Consumes: `External/libgit2/include/git2/submodule.h` at the pinned `v1.9.7` tag.
- Produces: `submoduleByUpdatingIgnoreRule:error:` either still functions or fails with a clear, testable `NSError` — no silent no-op.

- [ ] **Step 1: Check the real 1.9.7 header for `git_submodule_set_ignore`'s actual status**

```bash
grep -n -B3 -A3 "git_submodule_set_ignore" External/libgit2/include/git2/submodule.h
```
Determine from the real header (not from memory) whether the function: (a) still exists and works, (b) is marked `GIT_DEPRECATED` but still compiles and functions under the project's current `DEPRECATE_HARD` setting (which Task 5's build leaves at its default, `OFF`), or (c) has been removed from the header entirely.

- [ ] **Step 2: Apply the appropriate fix based on Step 1's finding**

- If (a) or (b): no functional change needed; if `GIT_DEPRECATED` triggers a `-Wdeprecated-declarations` warning that the project treats as an error, wrap the call site with the project's existing deprecation-silencing pattern (check `ObjectiveGit/GTIndex.m`'s `#pragma mark Deprecations` section for the codebase's established convention) rather than introducing a new one.
- If (c): the method can no longer set the ignore rule via libgit2. Change `submoduleByUpdatingIgnoreRule:error:` to populate `error` with a clear `NSError` (using the existing `[NSError git_errorFor:description:]` pattern already used elsewhere in this file) explaining the operation is unsupported by the current libgit2 version, and return `nil`, rather than silently doing nothing.

- [ ] **Step 3: Write/extend a test pinning Review Focus item 3**

Extend `ObjectiveGitTests/GTSubmoduleSpec.m`:
```objc
it(@"either updates the ignore rule or fails loudly, but never no-ops silently", ^{
	NSError *error = nil;
	GTSubmodule *updated = [submodule submoduleByUpdatingIgnoreRule:GTSubmoduleIgnoreRuleAll error:&error];

	if (updated == nil) {
		expect(error).notTo(beNil());
	} else {
		expect(updated.ignoreRule).to(equal(GTSubmoduleIgnoreRuleAll));
	}
});
```

- [ ] **Step 4: Run it**

Use the flowdeck skill to run `GTSubmoduleSpec`.
Expected: PASS — either the ignore rule genuinely changed, or a real error came back; not a silent pass-through where neither happened.

- [ ] **Step 5: Commit**

```bash
git add ObjectiveGit/GTSubmodule.m ObjectiveGit/GTSubmodule.h ObjectiveGitTests/GTSubmoduleSpec.m
git commit -m "Handle git_submodule_set_ignore deprecation in libgit2 1.9"
```

---

### Task 14: First full compile pass — fix whatever the real 1.9.7 headers surface

**Files:**
- Modify: any file under `ObjectiveGit/` the compiler flags (expected to be a small, currently-unknown set beyond Tasks 10–13, per the spec's explicit acknowledgment that the rename list is an estimate).

**Interfaces:**
- Consumes: everything from Tasks 1–13.
- Produces: a clean `ObjectiveGit-Mac` build — consumed by Task 15 (test target must also compile) and Task 16 (test suite needs a working framework to run against).

- [ ] **Step 1: Build and capture the first error**

Use the flowdeck skill to build the `ObjectiveGit-Mac` target.

- [ ] **Step 2: For each error, check the real header, then fix the call site**

```bash
grep -rn "<erroring symbol>" External/libgit2/include/
```
Read the surrounding declaration to find the modern name/signature, apply the minimal corresponding edit in the `ObjectiveGit/*.m`/`*.h` file, matching the style of the fixes already applied in Tasks 10–13 (rename in place, keep the ObjectiveGit-level public API identical unless the underlying libgit2 capability is genuinely gone).

- [ ] **Step 3: Repeat Steps 1–2 until the build succeeds with zero errors**

- [ ] **Step 4: Run the full `ObjectiveGitTests` compile (not yet the test suite itself — that's Task 16) to confirm the test target also builds**

Use the flowdeck skill to build (not run) the `ObjectiveGit-MacTests` target.
Expected: builds clean. (It may still fail to *link* until Task 15's SPM migration replaces the currently-broken Carthage-submodule Quick/Nimble/ZipArchive references — if so, note that and proceed to Task 15; this step's bar is "no ObjectiveGit-side compiler errors remain".)

- [ ] **Step 5: Commit whatever fixes were needed**

```bash
git add -A ObjectiveGit/
git commit -m "Fix remaining libgit2 1.9 API drift surfaced by the real compile"
```

---

### Task 15: Migrate Quick/Nimble/ZipArchive from Carthage submodules to SPM

**Files:**
- Delete: `Cartfile`, `Cartfile.private`, `Cartfile.resolved`
- Delete (submodules): `Carthage/Checkouts/Quick`, `Carthage/Checkouts/Nimble`, `Carthage/Checkouts/ZipArchive`, `Carthage/Checkouts/xcconfigs`
- Modify: `.gitmodules`
- Modify: `ObjectiveGitFramework.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: a compiling `ObjectiveGit-MacTests` target (Task 14).
- Produces: `ObjectiveGit-MacTests` linking Quick/Nimble/ZipArchive as SPM package products instead of Carthage subproject frameworks — consumed by Task 16 (running the suite).

**Context (from test-deps audit):** this project doesn't use classic Carthage binary frameworks — Quick/Nimble/ZipArchive/xcconfigs are git submodules whose `.xcodeproj`s are added as cross-project references, with `ObjectiveGit-MacTests` depending on their `Quick-macOS`/`Nimble-macOS`/`ZipArchive-Mac` targets directly and linking the resulting `.framework` products. `FRAMEWORK_SEARCH_PATHS` pointing at `Carthage/Build/Mac` is a vestigial fallback, not the real mechanism. Every spec file uses `@import Quick;`/`@import Nimble;`/`@import ZipArchive;` (Clang module syntax) — Review Focus item 4 is specifically about whether SPM-vended targets resolve that syntax the same way.

- [ ] **Step 1: Remove the Carthage cross-project wiring in Xcode**

In the project editor, remove the `ObjectiveGit-MacTests` target's dependencies on `Quick-macOS`, `Nimble-macOS`, `ZipArchive-Mac`, remove those three frameworks from its "Link Binary With Libraries" phase, and remove the `Quick.xcodeproj`/`Nimble.xcodeproj`/`ZipArchive.xcodeproj` file references from the project navigator (the "Carthage" group). Remove `FRAMEWORK_SEARCH_PATHS`'s `$(PROJECT_DIR)/Carthage/Build/Mac` entry from `ObjectiveGit-MacTests`'s build settings (all 4 configs).

- [ ] **Step 2: Add SPM package dependencies**

In the project editor, File → Add Package Dependencies, add:
- `https://github.com/Quick/Quick.git`, upToNextMajor from a version compatible with the project's minimum Swift tools version (use the latest Quick 7.x release available at implementation time — check `https://github.com/Quick/Quick/releases` for the current tag rather than assuming one here, since pinning an exact patch now would go stale by the time this task executes)
- `https://github.com/Quick/Nimble.git`, matching major version compatible with the chosen Quick release
- `https://github.com/ZipArchive/ZipArchive.git`, latest stable release

Add the `Quick`, `Nimble`, and `ZipArchive` (product name `SSZipArchive` — confirm the exact product name Xcode's package resolution offers, since the library target inside the ZipArchive package is `SSZipArchive`, not `ZipArchive`) library products as dependencies of the `ObjectiveGit-MacTests` target only (not `ObjectiveGit-Mac`).

- [ ] **Step 3: Remove the Carthage submodules and Cartfiles**

```bash
git submodule deinit -f Carthage/Checkouts/Quick Carthage/Checkouts/Nimble Carthage/Checkouts/ZipArchive Carthage/Checkouts/xcconfigs
git rm -f Carthage/Checkouts/Quick Carthage/Checkouts/Nimble Carthage/Checkouts/ZipArchive Carthage/Checkouts/xcconfigs
rm -rf .git/modules/Carthage
git rm Cartfile Cartfile.private Cartfile.resolved
```
Remove their four `[submodule "Carthage/Checkouts/..."]` stanzas from `.gitmodules`.

- [ ] **Step 4: Fix the `@import ZipArchive;` reference (Review Focus item 4)**

`QuickSpec+GTFixtures.m` has `@import ZipArchive;` but the SPM product/module is named `SSZipArchive`. Update to:
```objc
@import SSZipArchive;
```

- [ ] **Step 5: Build the test target and confirm module imports resolve**

Use the flowdeck skill to build `ObjectiveGit-MacTests`.
Expected: builds clean, including every file's `@import Quick;`/`@import Nimble;` and `QuickSpec+GTFixtures.m`'s `@import SSZipArchive;`. If any file fails to resolve `@import Quick;`/`@import Nimble;` as a Clang module (this is Review Focus item 4's actual failure mode), the fallback is switching that file's import to `#import <Quick/Quick.h>`/`#import <Nimble/Nimble.h>` — apply that uniformly across `ObjectiveGitTests/*.m` if needed, and note in the commit message that the fallback was required and why.

- [ ] **Step 6: Commit**

```bash
git add -A .gitmodules Cartfile Cartfile.private Cartfile.resolved Carthage ObjectiveGitFramework.xcodeproj ObjectiveGitTests/QuickSpec+GTFixtures.m
git commit -m "Migrate Quick, Nimble, and ZipArchive from Carthage submodules to Swift Package Manager"
```

---

### Task 16: Run the full test suite and triage failures

**Files:**
- Modify: whatever spec(s) surface real (not infrastructure) failures — see Step 2.

**Interfaces:**
- Consumes: a fully linking `ObjectiveGit-MacTests` target (Task 15).
- Produces: a passing (or explicitly triaged) `ObjectiveGitTests` suite — the spec's secondary bar.

- [ ] **Step 1: Run the full suite**

Use the flowdeck skill to run the `ObjectiveGit-MacTests` target (via the `ObjectiveGit Mac` scheme's Test action).

- [ ] **Step 2: For each failure, classify it**

For each failing spec, determine whether the failure is: (a) a genuine behavior regression from the libgit2/libssh2/mbedTLS bump (fix the `ObjectiveGit/` source), (b) a test relying on removed/changed libgit2 behavior that's no longer valid (update the spec's expectation, with a comment explaining why), or (c) environment-dependent (e.g., a fixture path assumption broken by the SPM migration's changed bundle layout — fix `QuickSpec+GTFixtures.m`'s fixture-lookup code). Do not silently skip or delete a failing spec without one of these three resolutions.

- [ ] **Step 3: Re-run until the suite is green or every remaining failure has a written triage note**

- [ ] **Step 4: Commit each fix as it's made** (one commit per distinct root cause, not one giant "fix tests" commit)

```bash
git add <affected files>
git commit -m "<specific description of what was fixed and why>"
```

---

### Task 17: Manual smoke test — real HTTPS and SSH clone

**Files:** none (manual verification task, no code changes expected unless it surfaces a bug).

**Interfaces:**
- Consumes: the packaged `.xcframework` (Task 9) or the built `ObjectiveGit.framework` directly.
- Produces: confirmation that Secure Transport (HTTPS) and mbedTLS-backed libssh2 (SSH) both work end-to-end against real remotes — the spec's tertiary/manual bar, and the only coverage for Review Focus item 5 (network-failure paths).

**Context:** none of the automated specs hit live network remotes (confirmed by the test-deps audit: fixtures are local zipped repos). This is the only check that exercises the real TLS/SSH stack this plan just replaced.

- [ ] **Step 1: Verify the built framework has zero Homebrew/user-tooling runtime dependencies**

```bash
otool -L build/ObjectiveGit.xcframework/macos-arm64/ObjectiveGit.framework/ObjectiveGit
```
Expected: only system paths (`/System/Library/...`, `/usr/lib/...`) plus the framework's own install name — no `/usr/local/...`, `/opt/homebrew/...`, or any other user-machine-specific path. This is the concrete check for the Global Constraints "zero runtime dependency on Homebrew" requirement (an App Store sandboxed app linking this framework must not implicitly require Homebrew or any other tooling on the end user's Mac). If any non-system path shows up, treat it as a build-configuration bug (most likely a static lib that got linked dynamically, or a `find_package` fallback in Tasks 3–5 that picked up a Homebrew-installed copy of mbedTLS/libssh2 instead of the vendored one) and fix it before proceeding.

- [ ] **Step 2: Write a small throwaway host program or a `GTRepositorySpec`-adjacent manual test** that calls `+cloneFromURL:toWorkingDirectory:options:error:transferProgressBlock:` against a real public HTTPS remote (e.g. a small public repo you control or a well-known public one) into a temp directory.

- [ ] **Step 3: Run it and confirm a real clone succeeds** — inspect the resulting working directory for the expected files, not just a non-error return.

- [ ] **Step 4: Repeat against a real `ssh://` remote you have key-based access to**, using `GTCredential credentialWithUserName:publicKeyURL:privateKeyURL:passphrase:error:` wired through a `GTCredentialProvider`.

- [ ] **Step 5: Confirm a real clone succeeds over SSH.**

- [ ] **Step 6: Deliberately break auth (wrong password / wrong SSH key) for both transports and confirm the failure surfaces as a proper `NSError`** (this is Review Focus item 5) rather than hanging, crashing, or returning a misleadingly-successful result.

- [ ] **Step 7: If any of the above fails, treat it as a real bug** — open it as a follow-up rather than silently shipping a framework whose core stated purpose (full HTTPS + SSH network support) doesn't actually work, and fix it before considering this plan complete.

- [ ] **Step 8: Note the outcome** (no code to commit unless Step 7 found something) — record which remotes/scenarios were exercised, since this step is not automated and won't be re-verified by CI (out of scope).

---

## Amendment: Tasks 18-22 (added post-Task-17)

Task 17's manual smoke test found that SSH client-key authentication was broken for effectively all real-world keys under the original mbedTLS-backed libssh2 build: mbedTLS's `mbedtls_pk_parse_keyfile()` cannot parse OpenSSH's `openssh-key-v1` private-key container format at all (`ssh-keygen`'s default output for every algorithm since OpenSSH 7.8 / 2018 — confirmed via a live repro: a legacy-PEM-format key worked, the modern default format failed with `MBEDTLS_ERR_PK_KEY_INVALID_FORMAT`), and separately libssh2's mbedTLS backend never implemented Ed25519 signing at all (`LIBSSH2_ED25519 0` in `External/libssh2/src/mbedtls.h`). Both are confirmed, root-caused, upstream/vendored-library gaps — not ObjectiveGit-level bugs — and neither has a small, safe, in-scope fix (implementing `openssh-key-v1` parsing plus bcrypt-pbkdf key derivation inside mbedTLS from scratch is a substantial new feature, not a patch). The human decided to reconsider the SSH crypto backend rather than ship with this gap: reintroduce OpenSSL, scoped only to libssh2's SSH-crypto leg (HTTPS remains on Secure Transport, untouched — this amendment does not touch `USE_HTTPS` or anything HTTPS-related). Confirmed via investigation: libgit2 itself has zero CMake-level dependency on mbedTLS (it uses its own builtin SHA1-with-collision-detection, selected via the CMake default, not mbedTLS) — mbedTLS's only consumer anywhere in this codebase is libssh2's `CRYPTO_BACKEND` selection, so it can be removed entirely once that's retargeted to OpenSSL. (Correction, post-final-review: keys parse successfully under the OpenSSL backend not because OpenSSL's own PEM parser natively understands `openssh-key-v1` — it doesn't — but because **libssh2 itself** parses that container format, in its own `pem.c` via `_libssh2_openssh_pem_parse` [including bcrypt-pbkdf key derivation], reached through a fallback path that libssh2's OpenSSL backend wires up when OpenSSL's native PEM parser doesn't recognize the format. mbedTLS's backend never wired up this same fallback path for anything except ECDSA, which is why RSA/Ed25519 with modern-format keys failed under mbedTLS specifically.)

### Task 18: Replace the mbedTLS submodule with OpenSSL

**Files:**
- Modify: `.gitmodules`
- Delete (submodule): `External/mbedtls`
- Create (submodule): `External/openssl`

**Interfaces:**
- Produces: a checked-out `External/openssl` submodule working tree pinned at tag `openssl-3.5.8` — consumed by Task 19's build script. Removes `External/mbedtls` — confirmed (Task 17 follow-up investigation) to have no other consumer anywhere in this codebase (libgit2's CMake config doesn't select mbedTLS for anything; grepping `External/libgit2/CMakeLists.txt` for `mbedtls`/`MBEDTLS` returns zero matches).

- [ ] **Step 1: Remove the mbedTLS submodule entirely**

```bash
git submodule deinit -f External/mbedtls
git rm -f External/mbedtls
rm -rf .git/modules/External/mbedtls
```
Then remove its `[submodule "External/mbedtls"]` stanza from `.gitmodules`.

- [ ] **Step 2: Add the OpenSSL submodule pinned to `openssl-3.5.8`**

```bash
git submodule add https://github.com/openssl/openssl.git External/openssl
git -C External/openssl fetch --tags
git -C External/openssl checkout openssl-3.5.8
```
`openssl-3.5.8` is OpenSSL's 3.5.x LTS line (supported until 2030-04-08 per OpenSSL's own release-strategy page) — the same version-pin rigor as the plan's other exact pins. Do not pin the newer 3.6.x line; it's OpenSSL's non-LTS line (support ends 2026-11-01).

- [ ] **Step 3: Verify submodule state**

```bash
git submodule status
```
Expected: `External/openssl` pinned at the `openssl-3.5.8` commit, no `External/mbedtls` entry, no `-` prefixes.

- [ ] **Step 4: Commit**

```bash
git add .gitmodules External/openssl
git commit -m "Replace mbedTLS submodule with OpenSSL 3.5.8 for libssh2's SSH crypto backend"
```

---

### Task 19: Add `script/update_openssl`

**Files:**
- Create: `script/update_openssl`
- Delete: `script/update_mbedtls`

**Interfaces:**
- Consumes: `External/openssl` submodule checkout (Task 18).
- Produces: `External/build/lib/libcrypto.a` (and `libssl.a`, built but unused — libssh2's OpenSSL `CRYPTO_BACKEND` links only `libcrypto`, confirmed against `External/libssh2/CMakeLists.txt`'s `CRYPTO_BACKEND STREQUAL "OpenSSL"` branch, which does `list(APPEND LIBSSH2_LIBS OpenSSL::Crypto)` and nothing else), headers under `External/build/include/openssl` — consumed by Task 20's libssh2 build (via the shared `External/build` prefix, same as mbedTLS's `CMAKE_PREFIX_PATH` role before it) and Task 21's Xcode aggregate/link-flag wiring.

**Context:** Unlike mbedTLS/libssh2/libgit2, OpenSSL does not use CMake — it has its own Perl-driven `Configure` + `make` build system. This requires Perl ≥5.10 (macOS's system `/usr/bin/perl`, currently 5.34.1, satisfies this) — this is a build-machine tool in the same category as the Homebrew-provided `cmake`/`autoconf`/etc. the plan's Global Constraints already treat as a build-time-only convenience, not a shipped-framework runtime dependency, so it doesn't violate the "zero Homebrew/user-tooling dependency" constraint. OpenSSL vendors its own fallback copy of the one non-core Perl module (`Text::Template`) its build needs, so a missing system copy of that module doesn't block the build — no CPAN/Homebrew install required.

- [ ] **Step 1: Create the script**

```sh
#!/bin/sh

set -e

ROOT_PATH=$(cd "$(dirname "$0")/.." && pwd)
EXTERNAL_BUILD_PATH="${ROOT_PATH}/External/build"

if [ "${EXTERNAL_BUILD_PATH}/lib/libcrypto.a" -nt "${ROOT_PATH}/External/openssl" ]
then
    echo "No update needed."
    exit 0
fi

cd "${ROOT_PATH}/External/openssl"

perl Configure darwin64-arm64-cc no-shared no-tests \
    --prefix="${EXTERNAL_BUILD_PATH}" \
    --openssldir="${EXTERNAL_BUILD_PATH}/ssl"
make -j"$(sysctl -n hw.ncpu)"
make install_dev

echo "OpenSSL has been updated."
```

Make it executable: `chmod +x script/update_openssl`. `no-shared` matches the project's existing static-linking convention; `install_dev` (a real target in OpenSSL's `Configurations/unix-Makefile.tmpl`) installs headers + static libs + pkgconfig only, skipping docs/man pages/the `openssl` CLI binary/engines — cheaper than plain `make install` and sufficient since only `libcrypto` gets linked into the framework.

- [ ] **Step 2: Delete the now-unused mbedTLS script**

```bash
git rm script/update_mbedtls
```

- [ ] **Step 3: Run the new script directly and confirm the expected artifacts appear**

```bash
script/update_openssl
ls External/build/lib/libcrypto.a
ls External/build/include/openssl/opensslv.h
lipo -info External/build/lib/libcrypto.a
```
Expected: `libcrypto.a` and the header exist; `lipo -info` reports `Non-fat file ... is architecture: arm64`.

- [ ] **Step 4: Commit**

```bash
git add script/update_openssl
git commit -m "Add script/update_openssl to build OpenSSL statically for arm64; remove script/update_mbedtls"
```

---

### Task 20: Retarget `script/update_libssh2` to the OpenSSL crypto backend

**Files:**
- Modify: `script/update_libssh2`

**Interfaces:**
- Consumes: `External/build/{include,lib}` OpenSSL artifacts (Task 19).
- Produces: `External/build/lib/libssh2.a` built against OpenSSL instead of mbedTLS — consumed by Task 21's Xcode wiring and Task 22's rebuild/re-verification.

- [ ] **Step 1: Change the `CRYPTO_BACKEND` selection**

In `script/update_libssh2`'s `cmake` invocation, change:
```
-DCRYPTO_BACKEND=mbedTLS \
```
to:
```
-DCRYPTO_BACKEND=OpenSSL \
-DOPENSSL_ROOT_DIR="${EXTERNAL_BUILD_PATH}" \
-DOPENSSL_USE_STATIC_LIBS=TRUE \
```
`CMAKE_PREFIX_PATH="${EXTERNAL_BUILD_PATH}"` (already present, unchanged) would resolve `find_package(OpenSSL)` on its own since Task 19 installs into the same shared prefix mbedTLS used before it — the explicit `OPENSSL_ROOT_DIR`/`OPENSSL_USE_STATIC_LIBS` hints remove any ambiguity from CMake's `FindOpenSSL.cmake` default search/preference order.

- [ ] **Step 2: Force a rebuild and confirm the backend selection**

```bash
rm -rf External/build/lib/libssh2.a External/libssh2/build
script/update_libssh2
```
Inspect the CMake configure output (re-run with `cd External/libssh2/build && cmake .. 2>&1 | grep -i "crypto backend"` if the first run's log scrolled past) for a line confirming `Crypto Backend: OpenSSL` (or equivalent) — same verification pattern the original plan used to confirm the mbedTLS selection in Task 4.

- [ ] **Step 3: Commit**

```bash
git add script/update_libssh2
git commit -m "Retarget script/update_libssh2 to the OpenSSL crypto backend"
```

---

### Task 21: Rewire the Xcode project from mbedTLS to OpenSSL

**Files:**
- Modify: `ObjectiveGitFramework.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 19/20's OpenSSL build outputs.
- Produces: an `ObjectiveGit-Mac` target whose aggregate-target build order is `openssl` → `libssh2` → `libgit2` and whose link flags reference `libcrypto.a` instead of the three `libmbed*.a` archives — consumed by Task 22's rebuild.

**Context:** Per the ledger's Task 7 tooling ruling (still binding), do this via the `xcodeproj` Ruby gem, not raw text hand-editing or Xcode-GUI clicking — the gem is already installed user-wide (v1.28.1) and every prior `.pbxproj` edit in this plan (Tasks 7, 8, 15, and the Task 16 scheme toggle) used it. Re-read the current `project.pbxproj`'s actual UUIDs/structure live before editing — do not assume the exact line numbers a prior investigation cited still hold verbatim; confirm the `mbedtls` aggregate target's real object identifiers and Run Script phase contents first.

- [ ] **Step 1: Replace the `mbedtls` aggregate target with an `openssl` aggregate target**

Rename (or delete-and-recreate, whichever the `xcodeproj` gem makes cleaner) the `mbedtls` `PBXAggregateTarget` to `openssl`. Update its Run Script build phase: `shellScript` from `script/update_mbedtls` to `script/update_openssl`; `inputPaths` from `$(SRCROOT)/External/mbedtls/CMakeLists.txt` to `$(SRCROOT)/External/openssl/Configure` (OpenSSL has no `CMakeLists.txt` — `Configure` is its build-system entry point); `outputPaths` from `$(SRCROOT)/External/build/lib/libmbedcrypto.a` to `$(SRCROOT)/External/build/lib/libcrypto.a`.

- [ ] **Step 2: Retarget the `libssh2` aggregate target's dependency**

`libssh2`'s target dependency currently points at `mbedtls` — retarget it to the renamed `openssl` target, preserving the same build-order constraint (crypto backend before libssh2 before libgit2) Task 7 originally established.

- [ ] **Step 3: Update `OTHER_LDFLAGS` in all four build configs (Debug/Release/Test/Profile)**

In each of the `ObjectiveGit-Mac` target's four `XCBuildConfiguration` blocks, remove these three entries:
```
"$(PROJECT_DIR)/External/build/lib/libmbedtls.a",
"$(PROJECT_DIR)/External/build/lib/libmbedcrypto.a",
"$(PROJECT_DIR)/External/build/lib/libmbedx509.a",
```
and add exactly one in their place:
```
"$(PROJECT_DIR)/External/build/lib/libcrypto.a",
```
(libssh2's OpenSSL backend links only `libcrypto`, never `libssl` — confirmed against the real vendored `External/libssh2/CMakeLists.txt`'s `CRYPTO_BACKEND STREQUAL "OpenSSL"` branch — do not add a `libssl.a` entry, it would be dead weight at best and a duplicate-symbol risk at worst). Leave the `libssh2.a`/`-lcurl`/`-framework Security` entries in each block untouched.

- [ ] **Step 4: Confirm no stale mbedTLS references remain**

```bash
grep -ri "mbedtls\|mbedcrypto\|mbedx509" ObjectiveGitFramework.xcodeproj/project.pbxproj
```
Expected: no matches.

- [ ] **Step 5: Verify target/build state**

Use the flowdeck skill to list the project's targets. Expected: aggregate targets are exactly `openssl`, `libssh2`, `libgit2` (in that dependency order); no `mbedtls` target remains.

- [ ] **Step 6: Commit**

```bash
git add ObjectiveGitFramework.xcodeproj
git commit -m "Rewire Xcode project from mbedTLS to OpenSSL: openssl aggregate target, OTHER_LDFLAGS across all 4 configs"
```

---

### Task 22: Full rebuild and re-verification of Task 17's SSH scenarios

**Files:** none expected (verification task) unless a new, small, genuinely-scoped bug surfaces.

**Interfaces:**
- Consumes: Tasks 18-21's OpenSSL-backed build.
- Produces: confirmation that the original plan's "full HTTPS + SSH network support" Global Constraint is actually met — closes out the gap Task 17 found.

- [ ] **Step 1: Clean rebuild**

```bash
script/clean_externals
```
Then use the flowdeck skill to build the `ObjectiveGit Mac` scheme and `flowdeck test` the `ObjectiveGit-MacTests` target. Expected: builds clean, all 291 `ObjectiveGitTests` still pass (this amendment doesn't touch HTTPS, libgit2, or any ObjectiveGit/ source — the automated suite has no live-network specs per Review Focus, so this is a regression check, not a new-coverage check).

- [ ] **Step 2: Re-run Task 17's `otool -L` check against the freshly-rebuilt framework**

```bash
script/create_xcframework
otool -L build/ObjectiveGit.xcframework/macos-arm64/ObjectiveGit.framework/ObjectiveGit
```
Expected: only system paths (`/System/Library/...`, `/usr/lib/...`) plus the framework's own install name — confirm `libcrypto`'s symbols were statically linked in (no dynamic `libcrypto.dylib`/`libssl.dylib` reference of any kind, Homebrew-provided or otherwise).

- [ ] **Step 3: Re-run the SSH golden-path scenario with a modern-default-format key**

Using the same approach Task 17 used (a fully local, throwaway sshd — loopback-only, unprivileged, no sudo, no system/account changes — or, if available, the real GitHub-registered key from Task 17), generate a **default-format** key (`ssh-keygen` with no `-m` flag — i.e. the actual `openssh-key-v1` format that was the original failure mode) and confirm `+[GTRepository cloneFromURL:...]` with `GTCredential credentialWithUserName:publicKeyURL:privateKeyURL:passphrase:error:` now succeeds. This is the specific, concrete regression check for the exact bug Task 17 found — a legacy `-m PEM` key succeeding is not sufficient evidence, since that already worked before this amendment.

- [ ] **Step 4: Re-run the SSH golden-path scenario with an Ed25519 key**

Same approach, using an Ed25519 key (default format). Confirm the clone succeeds — this is the regression check for the separate `LIBSSH2_ED25519 0` gap; OpenSSL's libssh2 backend supports Ed25519 signing, so this should now work where it categorically could not before.

- [ ] **Step 5: Re-run Task 17's SSH auth-failure scenario**

Confirm a deliberately-wrong key/passphrase still surfaces a proper `NSError` (not a hang/crash/false-success) under the new backend — same check as Task 17 Step 6, just re-run against OpenSSL instead of mbedTLS.

- [ ] **Step 6: If any of Steps 1-5 fails, treat it as a real bug** — this amendment exists specifically to close the gap Task 17 found; a failure here means the crypto-backend swap didn't actually fix it, which is new information the human needs, not something to silently work around.

- [ ] **Step 7: Note the outcome and commit if Step 6 found something**

```bash
git add <affected files>
git commit -m "<specific description>"
```
Record which scenarios were exercised and their outcomes — same "not re-verified by CI, this is the durable record" reasoning as Task 17 Step 8.

---

## Self-Review Notes

**Spec coverage:** Submodule bumps (Task 1), build scripts incl. mbedTLS/libssh2/libgit2 rewrites and iOS/stale script removal (Tasks 2–6), Xcode project settings incl. deployment target/arch/iOS removal/xcframework (Tasks 7–9), the two named ObjC renames plus the two audit-discovered risk pockets (Tasks 10–13), the open-ended "real compile is the source of truth" pass (Task 14), Carthage→SPM migration (Task 15), test suite triage (Task 16), and the manual network smoke test (Task 17) — every component in the design spec has an owning task.

**Placeholder scan:** no "TBD"/"handle appropriately"/"similar to Task N" patterns; every code block is real, and the two spots that can't be fully pinned ahead of time (Task 14's unknown remaining compile errors, Task 15's exact Quick/Nimble version) are written as concrete, verifiable procedures ("check the real header", "check the current release tag") rather than vague deferrals, consistent with how the design spec itself treats the same uncertainty.

**Type consistency:** `GTCredentialType`/`git_credential *`/`GTCredentialAcquireCallback` signatures match exactly across Task 10's header/implementation/private-header edits; `git_indexer_progress *` matches exactly across all six of Task 11's files; `GTTransferProgressBlock`/`GTRemoteFetchTransferProgressBlock` names are unchanged throughout (only their embedded C type changes).

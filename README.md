# ObjectiveGit

ObjectiveGit provides Cocoa bindings to the
[libgit2](https://github.com/libgit2/libgit2) library, packaged as an `.xcframework` for macOS 15 (Sequoia) or later, arm64 only. There is no iOS support.

## Features

A brief summary of the available functionality:

* Read: log, diff, blame, reflog, status
* Write: init, checkout, commit, branch, tag, reset
* Internals: configuration, tree, blob, object database
* Network: clone, fetch, push, pull
* Transports: HTTP, HTTPS, SSH, local filesystem

Not all libgit2 features are available, but if you run across something missing, please consider [contributing a pull request](#contributing)!

Many classes in the ObjectiveGit API wrap a C struct from libgit2 and expose the underlying data and operations using Cocoa idioms. The underlying libgit2 types are prefixed with `git_` and are often accessible via a property so that your application can take advantage of the [libgit2 API](https://libgit2.github.com/libgit2/#HEAD) directly.

The ObjectiveGit API makes extensive use of the Cocoa NSError pattern. The public API is also decorated with nullability attributes so that you will get compile-time feedback of whether nil is allowed or not. This also makes the framework much nicer to use in Swift.

## Getting Started

ObjectiveGit targets macOS 15 (Sequoia) or later, arm64 only, and is built with the current Xcode toolchain.

### Bootstrap

Run [`script/bootstrap`](script/bootstrap) to set up submodules and dependencies:

```
script/bootstrap
```

This script:

- Initializes and updates git submodules (libgit2, libssh2, OpenSSL, and the Carthage-vendored Quick/Nimble/ZipArchive/xcconfigs checkouts).
- Patches the Carthage-vendored submodules in place, via [`script/patch_carthage_dependencies.rb`](script/patch_carthage_dependencies.rb), so their old Xcode project settings (deployment targets, warning flags, etc.) work with the current Xcode toolchain. **It is expected and by design that `git status` will show `Carthage/Checkouts/Quick`, `Carthage/Checkouts/Nimble`, `Carthage/Checkouts/ZipArchive`, and `Carthage/Checkouts/xcconfigs` as "modified content" (dirty) after bootstrapping.** `script/bootstrap` reapplies this patch idempotently every run, since `git submodule update` would otherwise silently discard it. Do not run `git submodule update`/`git checkout` on those submodules to "clean" them.
- Ensures the build-time tools these libraries need (cmake, libtool, autoconf, automake, pkg-config) are installed via [Homebrew](http://brew.sh), prompting to install Homebrew itself if it's missing.

`script/patch_carthage_dependencies.rb` additionally requires the `xcodeproj` Ruby gem. If it isn't already installed:

```
gem install xcodeproj --user-install
```

To develop ObjectiveGit on its own, open the `ObjectiveGitFramework.xcworkspace` file.

### Building the framework

Build the vendored libgit2/libssh2/OpenSSL static libraries and package everything as an `.xcframework` with:

```
script/create_xcframework
```

This produces `build/ObjectiveGit.xcframework`. All third-party dependencies (libgit2, libssh2, OpenSSL's libcrypto) are statically linked; the resulting framework has no Homebrew or other user-tooling runtime dependency.

If you bump one of the vendored submodule versions (libgit2, libssh2, or OpenSSL), run [`script/clean_externals`](script/clean_externals) first to remove the stale build artifacts under `External/build`, since Xcode won't otherwise notice the submodule changed and will keep linking the old static libraries:

```
script/clean_externals
```

## Contributing

1. Fork this repository
1. Make it awesomer (preferably in a branch named for the topic)
1. Send a pull request

All contributions should match GitHub's [Objective-C coding
conventions](https://github.com/github/objective-c-style-guide).

You can see all the amazing people that have contributed to this project
[here](https://github.com/libgit2/objective-git/graphs/contributors).


## License

ObjectiveGit is released under the MIT license. See
the [LICENSE](LICENSE) file.

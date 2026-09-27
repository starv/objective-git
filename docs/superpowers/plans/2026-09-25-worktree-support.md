# Worktree Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add git worktree support to objective-git: a new `GTWorktree` wrapper class and a new `GTRepository+Worktree` category that can create, list, look up, prune, and open worktrees as full `GTRepository` instances.

**Architecture:** `GTWorktree` owns and frees a `git_worktree *` handle, following the exact `GTSubmodule` pattern (private `assign, readonly` property backing an `objc_returns_inner_pointer` accessor, `NS_UNAVAILABLE` init, `NS_DESIGNATED_INITIALIZER`, `-dealloc` frees the handle). `GTRepository+Worktree` is a new category (mirroring `GTRepository+Reset`) that creates/looks up/lists `GTWorktree`s and adds worktree-awareness (`isWorktree`, `commonGitDirectoryURL`, opening a `GTRepository` from a `GTWorktree`) to `GTRepository` itself.

**Tech Stack:** Objective-C, vendored libgit2 1.9.7 (`External/libgit2`, already exposes the full worktree API needed — no bump required), Quick 2.2.1 / Nimble 8.1.2 (BDD specs), Xcode project managed via the `xcodeproj` Ruby gem (confirmed installed) rather than hand-edited `project.pbxproj` hex IDs. On the current state - git status showing Carthage/Checkouts/{Nimble,Quick,ZipArchive,xcconfigs} as modified is the correct steady state after bootstrapping — it'll show that on every machine that runs script/bootstrap. It's called out explicitly in the README.

**Spec:** `docs/superpowers/specs/2026-09-25-worktree-support-design.md`. Executors should read both this plan and that spec; this plan is the source of truth for exact code/task breakdown, the spec is the source of truth for scope/rationale.

## Global Constraints

- Vendored libgit2 stays pinned at v1.9.7 (`External/libgit2/include/git2/version.h`) — every function used below already exists in that version; do not bump libgit2.
- Only the `ObjectiveGit-Mac` target needs `project.pbxproj` wiring for new framework files (no separate iOS target exists in this project); the `ObjectiveGit-MacTests` target needs wiring only for new spec files.
- New public headers (`GTWorktree.h`, `GTRepository+Worktree.h`) must get `ATTRIBUTES = (Public, )` in their `PBXBuildFile` entry and a matching `#import <ObjectiveGit/...>` line in `ObjectiveGit/ObjectiveGit.h`.
- Every fallible method takes a trailing `NSError **error` and wraps libgit2 error codes via `[NSError git_errorFor:code description:...]` — no new error-handling pattern.
- Use `git_strarray_dispose` (not the deprecated `git_strarray_free`) and drain `git_strarray`s via the existing `+[NSArray git_arrayWithStrarray:]` category — do not hand-roll the loop.
- No new fixture-zip content: worktrees are created fresh per test via `-tempDirectoryFileURL`; source repos use `-blankFixtureRepository` or `-bareFixtureRepository`.
- No `fdescribe`/`fit`/`fcontext` in committed specs (the mistake PR #642 shipped).
- Out of scope for this pass (per the design spec, do not implement): lock/unlock, `git_repository_head_for_worktree`, `git_repository_set_workdir`.
- This environment blocks raw `xcodebuild` invocations via a local hook; use `flowdeck build` / `flowdeck test` instead (a FlowDeck project config for this worktree is already saved). Never use `xcodebuild`, `xcrun`, or `xcode-select` directly.

## Review Focus

- Looking up a worktree name that doesn't exist: `-lookupWorktreeWithName:error:` must return `nil` and populate `NSError`, not crash or assert — covered in Task 3.
- Adding a worktree whose name collides with an existing one: `-addWorktreeWithName:URL:reference:error:` must surface an `NSError` and return `nil`, not silently succeed or crash — covered in Task 2.
- A repository with zero linked worktrees: `-worktreesWithError:` must return an empty `NSArray`, not `nil` and not an error — covered in Task 3.
- Calling `-isWorktree`/`-commonGitDirectoryURL` on an ordinary (non-worktree) repository: `isWorktree` must be `NO` and `commonGitDirectoryURL` must equal `gitDirectoryURL` — covered in Task 2.
- Pruning/checking prunability of a worktree that is still valid and checked out, without forcing flags: `-isPrunableWithOptions:0 error:` must be `NO` and `-pruneWithOptions:0 error:` must fail with an `NSError`, not silently no-op — covered in Task 1.

---

## File Structure

- Create `ObjectiveGit/GTWorktree.h` / `.m` — new wrapper class owning a `git_worktree *`.
- Create `ObjectiveGit/GTRepository+Worktree.h` / `.m` — new category: worktree creation, lookup, listing, and repository worktree-predicates.
- Create `ObjectiveGitTests/GTWorktreeSpec.m` — spec for `GTWorktree`.
- Create `ObjectiveGitTests/GTRepository+WorktreeSpec.m` — spec for `GTRepository+Worktree`.
- Modify `ObjectiveGit/ObjectiveGit.h` — add two new umbrella `#import`s.
- Modify `ObjectiveGitFramework.xcodeproj/project.pbxproj` — via an `xcodeproj`-gem Ruby script (not manual hex-ID editing) to register the new files with the `ObjectiveGit-Mac` and `ObjectiveGit-MacTests` targets.

Build/test command used throughout: this environment blocks raw `xcodebuild` calls via a local hook and requires the FlowDeck CLI instead. A FlowDeck project config (workspace `ObjectiveGitFramework.xcworkspace`, scheme `ObjectiveGit Mac`, target `My Mac`) is already saved for this worktree (`flowdeck config get --json` confirms it) — use the bare commands:

```bash
flowdeck build 2>&1 | tail -60
flowdeck test 2>&1 | tail -100
```

`flowdeck test` builds the test target and runs the full suite in one step (equivalent to `xcodebuild ... build test`). A clean baseline of 291/291 existing tests passing was confirmed in this worktree before Task 1 was dispatched.

---

### Task 1: `GTWorktree` class

**Files:**
- Create: `ObjectiveGit/GTWorktree.h`
- Create: `ObjectiveGit/GTWorktree.m`
- Modify: `ObjectiveGit/ObjectiveGit.h`
- Modify: `ObjectiveGitFramework.xcodeproj/project.pbxproj` (via Ruby script below)
- Test: `ObjectiveGitTests/GTWorktreeSpec.m`

**Interfaces:**
- Consumes: `[NSError git_errorFor:description:]` (`ObjectiveGit/Categories/NSError+Git.h`); libgit2 `git_worktree_*` C API (`External/libgit2/include/git2/worktree.h`).
- Produces: `GTWorktree` class with `-name` (`NSString *`), `-worktreeURL` (`NSURL *`), `-git_worktree` (inner pointer, `git_worktree *`), `-initWithGitWorktree:` (designated initializer), `-isValidWithError:`, `-isPrunableWithOptions:error:`, `-pruneWithOptions:error:` (all `BOOL`, trailing `NSError **`), and `GTWorktreePruneOptions` (`NS_OPTIONS(NSUInteger, ...)` with `GTWorktreePruneOptionsValid`, `GTWorktreePruneOptionsLocked`, `GTWorktreePruneOptionsWorkingTree`). These are consumed by Task 2/3's `GTRepository+Worktree`.

- [ ] **Step 1: Write the failing spec file**

Create `ObjectiveGitTests/GTWorktreeSpec.m`:

```objc
//
//  GTWorktreeSpec.m
//  ObjectiveGitFramework
//

@import ObjectiveGit;
@import Nimble;
@import Quick;

#import "QuickSpec+GTFixtures.h"
#import "git2/worktree.h"

QuickSpecBegin(GTWorktreeSpec)

__block GTRepository *repo;
__block GTWorktree *worktree;
__block NSURL *worktreeURL;

beforeEach(^{
	repo = self.blankFixtureRepository;
	expect(repo).notTo(beNil());

	worktreeURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"linked-worktree"];

	git_worktree_add_options addOptions;
	int initError = git_worktree_add_options_init(&addOptions, GIT_WORKTREE_ADD_OPTIONS_VERSION);
	expect(@(initError)).to(equal(@(GIT_OK)));

	git_worktree *rawWorktree = NULL;
	int gitError = git_worktree_add(&rawWorktree, repo.git_repository, "linked-worktree", worktreeURL.fileSystemRepresentation, &addOptions);
	expect(@(gitError)).to(equal(@(GIT_OK)));

	worktree = [[GTWorktree alloc] initWithGitWorktree:rawWorktree];
	expect(worktree).notTo(beNil());
});

it(@"should report its name", ^{
	expect(worktree.name).to(equal(@"linked-worktree"));
});

it(@"should report its worktree URL", ^{
	expect(worktree.worktreeURL.path).to(equal(worktreeURL.path));
});

it(@"should be valid immediately after creation", ^{
	NSError *error = nil;
	expect(@([worktree isValidWithError:&error])).to(beTruthy());
	expect(error).to(beNil());
});

it(@"should not be prunable while its working tree is still checked out and valid", ^{
	NSError *error = nil;
	expect(@([worktree isPrunableWithOptions:0 error:&error])).to(beFalsy());
	expect(error).to(beNil());
});

it(@"should be prunable when the valid and working-tree flags are forced", ^{
	NSError *error = nil;
	GTWorktreePruneOptions options = GTWorktreePruneOptionsValid | GTWorktreePruneOptionsWorkingTree;
	expect(@([worktree isPrunableWithOptions:options error:&error])).to(beTruthy());
	expect(error).to(beNil());
});

it(@"should fail to prune while its working tree is still checked out and valid", ^{
	NSError *error = nil;
	expect(@([worktree pruneWithOptions:0 error:&error])).to(beFalsy());
	expect(error).notTo(beNil());
});

it(@"should prune successfully when the valid and working-tree flags are forced", ^{
	NSError *error = nil;
	GTWorktreePruneOptions options = GTWorktreePruneOptionsValid | GTWorktreePruneOptionsWorkingTree;
	expect(@([worktree pruneWithOptions:options error:&error])).to(beTruthy());
	expect(error).to(beNil());
});

afterEach(^{
	[self tearDown];
});

QuickSpecEnd
```

- [ ] **Step 2: Wire the spec file into the test target**

Run:

```bash
ruby <<'RUBY'
require 'xcodeproj'

project = Xcodeproj::Project.open('ObjectiveGitFramework.xcodeproj')

test_target = project.targets.find { |t| t.name == 'ObjectiveGit-MacTests' }
raise 'ObjectiveGit-MacTests target not found' if test_target.nil?

test_group = project.files.find { |f| f.path == 'GTSubmoduleSpec.m' }&.parent
raise 'GTSubmoduleSpec.m file reference not found (bad anchor)' if test_group.nil?

spec_ref = test_group.new_file('GTWorktreeSpec.m')
test_target.source_build_phase.add_file_reference(spec_ref)

project.save
puts 'Added GTWorktreeSpec.m to ObjectiveGit-MacTests.'
RUBY
```

- [ ] **Step 3: Run the build/tests to confirm it fails to compile**

```bash
flowdeck test 2>&1 | tail -100
```

(A FlowDeck project config is already saved for this worktree — `flowdeck test` uses it with no flags needed. Raw `xcodebuild` is blocked in this environment.)

Expected: FAIL — compile error in `GTWorktreeSpec.m` such as "use of undeclared identifier 'GTWorktree'" or "unknown type name 'GTWorktree'", since the class doesn't exist yet.

- [ ] **Step 4: Write `GTWorktree.h`**

Create `ObjectiveGit/GTWorktree.h`:

```objc
//
//  GTWorktree.h
//  ObjectiveGitFramework
//

#import <Foundation/Foundation.h>

#import "git2/worktree.h"

NS_ASSUME_NONNULL_BEGIN

/// Options for pruning a worktree. See the libgit2 documentation
/// (`git_worktree_prune_t`) for more info.
typedef NS_OPTIONS(NSUInteger, GTWorktreePruneOptions) {
	/// Prune the worktree even if it is still valid.
	GTWorktreePruneOptionsValid = GIT_WORKTREE_PRUNE_VALID,
	/// Prune the worktree even if it is locked.
	GTWorktreePruneOptionsLocked = GIT_WORKTREE_PRUNE_LOCKED,
	/// Prune the checked-out working tree of the worktree as well.
	GTWorktreePruneOptionsWorkingTree = GIT_WORKTREE_PRUNE_WORKING_TREE,
};

/// A linked git worktree, as created by `git worktree add`.
@interface GTWorktree : NSObject

/// The name of the worktree.
@property (nonatomic, readonly, copy) NSString *name;

/// The location of the worktree's working directory on disk.
@property (nonatomic, readonly, copy) NSURL *worktreeURL;

- (instancetype)init NS_UNAVAILABLE;

/// Initializes the receiver to wrap the given worktree object. Designated initializer.
///
/// worktree - The worktree to wrap. The receiver takes ownership of this
///            object and will free it on -dealloc. This must not be NULL.
///
/// Returns an initialized GTWorktree, or nil if an error occurs.
- (instancetype _Nullable)initWithGitWorktree:(git_worktree *)worktree NS_DESIGNATED_INITIALIZER;

/// The underlying `git_worktree` object.
- (git_worktree *)git_worktree __attribute__((objc_returns_inner_pointer));

/// Checks whether the worktree is valid — i.e. still registered with its
/// parent repository and pointing at an existing directory.
///
/// error - The error if one occurred.
///
/// Returns whether the worktree is valid.
- (BOOL)isValidWithError:(NSError **)error;

/// Checks whether the worktree can be pruned.
///
/// options - The options to use when checking prunability.
/// error   - The error if one occurred.
///
/// Returns whether the worktree can be pruned.
- (BOOL)isPrunableWithOptions:(GTWorktreePruneOptions)options error:(NSError **)error;

/// Prunes (removes the administrative files for) the worktree.
///
/// options - The options to use when pruning.
/// error   - The error if one occurred.
///
/// Returns whether the prune succeeded.
- (BOOL)pruneWithOptions:(GTWorktreePruneOptions)options error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 5: Write `GTWorktree.m`**

Create `ObjectiveGit/GTWorktree.m`:

```objc
//
//  GTWorktree.m
//  ObjectiveGitFramework
//

#import "GTWorktree.h"
#import "NSError+Git.h"

#import "git2/errors.h"

@interface GTWorktree ()
@property (nonatomic, assign, readonly) git_worktree *git_worktree;
@end

@implementation GTWorktree

#pragma mark Lifecycle

- (instancetype)init {
	NSAssert(NO, @"Call to an unavailable initializer.");
	return nil;
}

- (instancetype)initWithGitWorktree:(git_worktree *)worktree {
	NSParameterAssert(worktree != NULL);

	self = [super init];
	if (self == nil) return nil;

	_git_worktree = worktree;

	return self;
}

- (void)dealloc {
	if (_git_worktree != NULL) {
		git_worktree_free(_git_worktree);
	}
}

#pragma mark Properties

- (NSString *)name {
	const char *cName = git_worktree_name(self.git_worktree);
	NSAssert(cName != NULL, @"Every worktree should have a name");
	return @(cName);
}

- (NSURL *)worktreeURL {
	const char *cPath = git_worktree_path(self.git_worktree);
	NSAssert(cPath != NULL, @"Every worktree should have a path");
	return [NSURL fileURLWithPath:@(cPath) isDirectory:YES];
}

#pragma mark Validity & pruning

- (BOOL)isValidWithError:(NSError **)error {
	int gitError = git_worktree_validate(self.git_worktree);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Worktree %@ is not valid.", self.name];
		return NO;
	}

	return YES;
}

- (BOOL)isPrunableWithOptions:(GTWorktreePruneOptions)options error:(NSError **)error {
	git_worktree_prune_options opts;
	int gitError = git_worktree_prune_options_init(&opts, GIT_WORKTREE_PRUNE_OPTIONS_VERSION);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to initialize worktree prune options."];
		return NO;
	}

	opts.flags = (uint32_t)options;

	int result = git_worktree_is_prunable(self.git_worktree, &opts);
	if (result < GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:result description:@"Failed to determine whether worktree %@ is prunable.", self.name];
		return NO;
	}

	return result == 1;
}

- (BOOL)pruneWithOptions:(GTWorktreePruneOptions)options error:(NSError **)error {
	git_worktree_prune_options opts;
	int gitError = git_worktree_prune_options_init(&opts, GIT_WORKTREE_PRUNE_OPTIONS_VERSION);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to initialize worktree prune options."];
		return NO;
	}

	opts.flags = (uint32_t)options;

	gitError = git_worktree_prune(self.git_worktree, &opts);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to prune worktree %@.", self.name];
		return NO;
	}

	return YES;
}

@end
```

- [ ] **Step 6: Wire the new class into the framework target and umbrella header**

Run:

```bash
ruby <<'RUBY'
require 'xcodeproj'

project = Xcodeproj::Project.open('ObjectiveGitFramework.xcodeproj')

main_target = project.targets.find { |t| t.name == 'ObjectiveGit-Mac' }
raise 'ObjectiveGit-Mac target not found' if main_target.nil?

main_group = project.files.find { |f| f.path == 'GTSubmodule.h' }&.parent
raise 'GTSubmodule.h file reference not found (bad anchor)' if main_group.nil?

header_ref = main_group.new_file('GTWorktree.h')
source_ref = main_group.new_file('GTWorktree.m')

main_target.source_build_phase.add_file_reference(source_ref)
header_build_file = main_target.headers_build_phase.add_file_reference(header_ref)
header_build_file.settings = { 'ATTRIBUTES' => ['Public'] }

project.save
puts 'Added GTWorktree.h/.m to ObjectiveGit-Mac.'
RUBY
```

Then edit `ObjectiveGit/ObjectiveGit.h` to add the umbrella import right after `GTSubmodule.h`:

```objc
#import <ObjectiveGit/GTSubmodule.h>
#import <ObjectiveGit/GTWorktree.h>
```

- [ ] **Step 7: Run the build/tests to confirm they pass**

```bash
flowdeck test 2>&1 | tail -100
```

(A FlowDeck project config is already saved for this worktree — `flowdeck test` uses it with no flags needed. Raw `xcodebuild` is blocked in this environment.)

Expected: PASS — `GTWorktreeSpec` (all 7 examples) plus the full existing suite green.

- [ ] **Step 8: Commit**

```bash
git add ObjectiveGit/GTWorktree.h ObjectiveGit/GTWorktree.m ObjectiveGit/ObjectiveGit.h \
        ObjectiveGitTests/GTWorktreeSpec.m ObjectiveGitFramework.xcodeproj/project.pbxproj
git commit -m "Add GTWorktree wrapper class"
```

---

### Task 2: `GTRepository+Worktree` — creation and repository predicates

**Files:**
- Create: `ObjectiveGit/GTRepository+Worktree.h`
- Create: `ObjectiveGit/GTRepository+Worktree.m`
- Modify: `ObjectiveGit/ObjectiveGit.h`
- Modify: `ObjectiveGitFramework.xcodeproj/project.pbxproj` (via Ruby script below)
- Test: `ObjectiveGitTests/GTRepository+WorktreeSpec.m`

**Interfaces:**
- Consumes: `GTWorktree` and `-initWithGitWorktree:` from Task 1; `self.git_repository` (`GTRepository.h:227`, existing); `[NSError git_errorFor:description:]`; `GTReference.git_reference` (existing, `GTReference.h:87`); `+[GTRepository repositoryWithURL:error:]` and `-headReferenceWithError:` and `-lookUpReferenceWithName:error:` (all existing, used only in the test).
- Produces: `GTRepository (Worktree)` category with `@property (nonatomic, readonly, getter=isWorktree) BOOL worktree;`, `@property (nonatomic, readonly, copy) NSURL *commonGitDirectoryURL;`, and `- (GTWorktree * _Nullable)addWorktreeWithName:(NSString *)name URL:(NSURL *)worktreeURL reference:(GTReference * _Nullable)reference error:(NSError **)error;`. Task 3 extends this same category (declares `repositoryWithWorktree:`/`initWithWorktree:`/`worktreesWithError:`/`lookupWorktreeWithName:error:` on it) and its `.m` reuses `addWorktreeWithName:` in tests indirectly via the shared `repo` fixture.

- [ ] **Step 1: Write the failing spec file**

Create `ObjectiveGitTests/GTRepository+WorktreeSpec.m`:

```objc
//
//  GTRepository+WorktreeSpec.m
//  ObjectiveGitFramework
//

@import ObjectiveGit;
@import Nimble;
@import Quick;

#import "QuickSpec+GTFixtures.h"

QuickSpecBegin(GTRepositoryWorktreeSpec)

__block GTRepository *repo;

beforeEach(^{
	repo = self.bareFixtureRepository;
	expect(repo).notTo(beNil());
});

it(@"should not be a worktree itself", ^{
	expect(@(repo.isWorktree)).to(beFalsy());
});

it(@"should report a common git directory URL equal to its own git directory for a non-worktree repository", ^{
	expect(repo.commonGitDirectoryURL.path).to(equal(repo.gitDirectoryURL.path));
});

describe(@"adding a worktree", ^{
	__block NSURL *worktreeURL;

	beforeEach(^{
		worktreeURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"new-worktree"];
	});

	it(@"should create a worktree checked out to a new branch from HEAD when no reference is given", ^{
		NSError *error = nil;
		GTWorktree *worktree = [repo addWorktreeWithName:@"new-worktree" URL:worktreeURL reference:nil error:&error];
		expect(worktree).notTo(beNil());
		expect(error).to(beNil());

		expect(worktree.name).to(equal(@"new-worktree"));
		expect(worktree.worktreeURL.path).to(equal(worktreeURL.path));

		GTRepository *worktreeRepo = [GTRepository repositoryWithURL:worktreeURL error:&error];
		expect(worktreeRepo).notTo(beNil());
		expect(@(worktreeRepo.isWorktree)).to(beTruthy());
	});

	it(@"should check out the given reference into the new worktree", ^{
		NSError *error = nil;
		GTReference *masterRef = [repo lookUpReferenceWithName:@"refs/heads/master" error:&error];
		expect(masterRef).notTo(beNil());
		expect(error).to(beNil());

		GTWorktree *worktree = [repo addWorktreeWithName:@"from-master" URL:worktreeURL reference:masterRef error:&error];
		expect(worktree).notTo(beNil());
		expect(error).to(beNil());

		GTRepository *worktreeRepo = [GTRepository repositoryWithURL:worktreeURL error:&error];
		expect(worktreeRepo).notTo(beNil());

		GTReference *worktreeHead = [worktreeRepo headReferenceWithError:&error];
		expect(worktreeHead.name).to(equal(@"refs/heads/master"));
	});

	it(@"should fail with an error when a worktree with the same name already exists", ^{
		NSError *error = nil;
		GTWorktree *worktree = [repo addWorktreeWithName:@"duplicate" URL:worktreeURL reference:nil error:&error];
		expect(worktree).notTo(beNil());
		expect(error).to(beNil());

		NSURL *secondURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"duplicate-again"];
		error = nil;
		GTWorktree *duplicate = [repo addWorktreeWithName:@"duplicate" URL:secondURL reference:nil error:&error];
		expect(duplicate).to(beNil());
		expect(error).notTo(beNil());
	});
});

afterEach(^{
	[self tearDown];
});

QuickSpecEnd
```

- [ ] **Step 2: Wire the spec file into the test target**

Run:

```bash
ruby <<'RUBY'
require 'xcodeproj'

project = Xcodeproj::Project.open('ObjectiveGitFramework.xcodeproj')

test_target = project.targets.find { |t| t.name == 'ObjectiveGit-MacTests' }
raise 'ObjectiveGit-MacTests target not found' if test_target.nil?

test_group = project.files.find { |f| f.path == 'GTSubmoduleSpec.m' }&.parent
raise 'GTSubmoduleSpec.m file reference not found (bad anchor)' if test_group.nil?

spec_ref = test_group.new_file('GTRepository+WorktreeSpec.m')
test_target.source_build_phase.add_file_reference(spec_ref)

project.save
puts 'Added GTRepository+WorktreeSpec.m to ObjectiveGit-MacTests.'
RUBY
```

- [ ] **Step 3: Run the build/tests to confirm it fails to compile**

```bash
flowdeck test 2>&1 | tail -100
```

(A FlowDeck project config is already saved for this worktree — `flowdeck test` uses it with no flags needed. Raw `xcodebuild` is blocked in this environment.)

Expected: FAIL — compile error such as "property 'isWorktree' not found on object of type 'GTRepository *'" or "no visible @interface for 'GTRepository' declares the selector 'addWorktreeWithName:URL:reference:error:'".

- [ ] **Step 4: Write `GTRepository+Worktree.h`**

Create `ObjectiveGit/GTRepository+Worktree.h`:

```objc
//
//  GTRepository+Worktree.h
//  ObjectiveGitFramework
//

#import "GTRepository.h"

#import "git2/worktree.h"

@class GTWorktree;
@class GTReference;

NS_ASSUME_NONNULL_BEGIN

@interface GTRepository (Worktree)

/// Whether the repository is a linked worktree (as opposed to the main
/// working tree, or a bare repository).
@property (nonatomic, readonly, getter=isWorktree) BOOL worktree;

/// The path to the repository's "common" git directory — for a linked
/// worktree, this is the main repository's `.git` directory (shared refs,
/// objects, etc.); for any other repository, it's the same as
/// `gitDirectoryURL`.
@property (nonatomic, readonly, copy) NSURL *commonGitDirectoryURL;

/// Creates a new linked worktree for the receiver.
///
/// name        - The name to give the new worktree. Cannot be nil.
/// worktreeURL - The location on disk at which to create the worktree's
///               working directory. Cannot be nil.
/// reference   - The branch to check out into the new worktree. If nil,
///               libgit2 creates and checks out a new branch named `name`
///               from the repository's current HEAD.
/// error       - The error if one occurred.
///
/// Returns the new worktree, or nil if an error occurred.
- (GTWorktree * _Nullable)addWorktreeWithName:(NSString *)name
                                           URL:(NSURL *)worktreeURL
                                     reference:(GTReference * _Nullable)reference
                                         error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 5: Write `GTRepository+Worktree.m`**

Create `ObjectiveGit/GTRepository+Worktree.m`:

```objc
//
//  GTRepository+Worktree.m
//  ObjectiveGitFramework
//

#import "GTRepository+Worktree.h"
#import "GTWorktree.h"
#import "GTReference.h"
#import "NSError+Git.h"

#import "git2/errors.h"

@implementation GTRepository (Worktree)

- (BOOL)isWorktree {
	return git_repository_is_worktree(self.git_repository) != 0;
}

- (NSURL *)commonGitDirectoryURL {
	const char *cPath = git_repository_commondir(self.git_repository);
	NSAssert(cPath != NULL, @"Every repository should have a common git directory");
	return [NSURL fileURLWithPath:@(cPath) isDirectory:YES];
}

- (GTWorktree *)addWorktreeWithName:(NSString *)name URL:(NSURL *)worktreeURL reference:(GTReference *)reference error:(NSError **)error {
	NSParameterAssert(name != nil);
	NSParameterAssert(worktreeURL != nil);

	git_worktree_add_options options;
	int gitError = git_worktree_add_options_init(&options, GIT_WORKTREE_ADD_OPTIONS_VERSION);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to initialize worktree add options."];
		return nil;
	}

	if (reference != nil) options.ref = reference.git_reference;

	git_worktree *worktree;
	gitError = git_worktree_add(&worktree, self.git_repository, name.UTF8String, worktreeURL.fileSystemRepresentation, &options);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to add worktree %@.", name];
		return nil;
	}

	return [[GTWorktree alloc] initWithGitWorktree:worktree];
}

@end
```

- [ ] **Step 6: Wire the new category into the framework target and umbrella header**

Run:

```bash
ruby <<'RUBY'
require 'xcodeproj'

project = Xcodeproj::Project.open('ObjectiveGitFramework.xcodeproj')

main_target = project.targets.find { |t| t.name == 'ObjectiveGit-Mac' }
raise 'ObjectiveGit-Mac target not found' if main_target.nil?

main_group = project.files.find { |f| f.path == 'GTSubmodule.h' }&.parent
raise 'GTSubmodule.h file reference not found (bad anchor)' if main_group.nil?

header_ref = main_group.new_file('GTRepository+Worktree.h')
source_ref = main_group.new_file('GTRepository+Worktree.m')

main_target.source_build_phase.add_file_reference(source_ref)
header_build_file = main_target.headers_build_phase.add_file_reference(header_ref)
header_build_file.settings = { 'ATTRIBUTES' => ['Public'] }

project.save
puts 'Added GTRepository+Worktree.h/.m to ObjectiveGit-Mac.'
RUBY
```

Then edit `ObjectiveGit/ObjectiveGit.h` to add the umbrella import alongside the other `GTRepository+*` category imports:

```objc
#import <ObjectiveGit/GTRepository+Merging.h>
#import <ObjectiveGit/GTRepository+Worktree.h>
```

- [ ] **Step 7: Run the build/tests to confirm they pass**

```bash
flowdeck test 2>&1 | tail -100
```

(A FlowDeck project config is already saved for this worktree — `flowdeck test` uses it with no flags needed. Raw `xcodebuild` is blocked in this environment.)

Expected: PASS — `GTRepositoryWorktreeSpec` (5 examples so far) plus the full existing suite green.

- [ ] **Step 8: Commit**

```bash
git add ObjectiveGit/GTRepository+Worktree.h ObjectiveGit/GTRepository+Worktree.m ObjectiveGit/ObjectiveGit.h \
        ObjectiveGitTests/GTRepository+WorktreeSpec.m ObjectiveGitFramework.xcodeproj/project.pbxproj
git commit -m "Add GTRepository+Worktree creation and worktree predicates"
```

---

### Task 3: `GTRepository+Worktree` — lookup, listing, and opening a worktree as a repository

**Files:**
- Modify: `ObjectiveGit/GTRepository+Worktree.h`
- Modify: `ObjectiveGit/GTRepository+Worktree.m`
- Modify: `ObjectiveGitTests/GTRepository+WorktreeSpec.m`

No `project.pbxproj` changes needed — all files already registered by Task 2.

**Interfaces:**
- Consumes: `-addWorktreeWithName:URL:reference:error:` (Task 2, used to set up worktrees to look up/list); `GTWorktree` and `-initWithGitWorktree:` (Task 1); `+[NSArray git_arrayWithStrarray:]` (existing, `ObjectiveGit/Categories/NSArray+StringArray.h`); `-initWithGitRepository:` (existing designated initializer, `GTRepository.h:224`).
- Produces: `+ (instancetype _Nullable)repositoryWithWorktree:(GTWorktree *)worktree error:(NSError **)error;`, `- (instancetype _Nullable)initWithWorktree:(GTWorktree *)worktree error:(NSError **)error;`, `- (NSArray<GTWorktree *> * _Nullable)worktreesWithError:(NSError **)error;`, `- (GTWorktree * _Nullable)lookupWorktreeWithName:(NSString *)name error:(NSError **)error;` — this completes the `GTRepository (Worktree)` category's public surface per the design spec.

- [ ] **Step 1: Extend the spec file with failing tests**

Edit `ObjectiveGitTests/GTRepository+WorktreeSpec.m`, inserting the following before the trailing `afterEach(^{ [self tearDown]; });` / `QuickSpecEnd`:

```objc
it(@"should return an empty array when the repository has no linked worktrees", ^{
	NSError *error = nil;
	NSArray<GTWorktree *> *worktrees = [repo worktreesWithError:&error];
	expect(worktrees).notTo(beNil());
	expect(@(worktrees.count)).to(equal(@0));
	expect(error).to(beNil());
});

describe(@"looking up and listing worktrees", ^{
	__block GTWorktree *addedWorktree;
	__block NSURL *worktreeURL;

	beforeEach(^{
		worktreeURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"listed-worktree"];

		NSError *error = nil;
		addedWorktree = [repo addWorktreeWithName:@"listed-worktree" URL:worktreeURL reference:nil error:&error];
		expect(addedWorktree).notTo(beNil());
		expect(error).to(beNil());
	});

	it(@"should list the added worktree by name", ^{
		NSError *error = nil;
		NSArray<GTWorktree *> *worktrees = [repo worktreesWithError:&error];
		expect(worktrees).notTo(beNil());
		expect(error).to(beNil());

		NSArray<NSString *> *names = [worktrees valueForKey:@"name"];
		expect(@([names containsObject:@"listed-worktree"])).to(beTruthy());
	});

	it(@"should look up the added worktree by name", ^{
		NSError *error = nil;
		GTWorktree *found = [repo lookupWorktreeWithName:@"listed-worktree" error:&error];
		expect(found).notTo(beNil());
		expect(error).to(beNil());
		expect(found.worktreeURL.path).to(equal(worktreeURL.path));
	});

	it(@"should fail to look up a worktree that doesn't exist", ^{
		NSError *error = nil;
		GTWorktree *found = [repo lookupWorktreeWithName:@"does-not-exist" error:&error];
		expect(found).to(beNil());
		expect(error).notTo(beNil());
	});

	it(@"should open the worktree as a fully-functional repository", ^{
		NSError *error = nil;
		GTRepository *worktreeRepo = [GTRepository repositoryWithWorktree:addedWorktree error:&error];
		expect(worktreeRepo).notTo(beNil());
		expect(error).to(beNil());

		expect(@(worktreeRepo.isWorktree)).to(beTruthy());

		GTReference *head = [worktreeRepo headReferenceWithError:&error];
		expect(head).notTo(beNil());
	});
});
```

- [ ] **Step 2: Run the build/tests to confirm it fails to compile**

```bash
flowdeck test 2>&1 | tail -100
```

(A FlowDeck project config is already saved for this worktree — `flowdeck test` uses it with no flags needed. Raw `xcodebuild` is blocked in this environment.)

Expected: FAIL — compile error such as "no visible @interface for 'GTRepository' declares the selector 'worktreesWithError:'" (and similarly for `lookupWorktreeWithName:error:` / `repositoryWithWorktree:error:`).

- [ ] **Step 3: Extend `GTRepository+Worktree.h`**

Edit `ObjectiveGit/GTRepository+Worktree.h`, adding these declarations inside `@interface GTRepository (Worktree)`, after the existing `addWorktreeWithName:URL:reference:error:` declaration and before `@end`:

```objc

/// Opens the repository associated with a worktree.
///
/// worktree - The worktree to open. Cannot be nil.
/// error    - The error if one occurred.
///
/// Returns a new repository for operating inside the worktree, or nil if an
/// error occurred.
+ (instancetype _Nullable)repositoryWithWorktree:(GTWorktree *)worktree error:(NSError **)error;

/// Initializes the receiver with the repository associated with a worktree.
///
/// worktree - The worktree to open. Cannot be nil.
/// error    - The error if one occurred.
///
/// Returns an initialized repository, or nil if an error occurred.
- (instancetype _Nullable)initWithWorktree:(GTWorktree *)worktree error:(NSError **)error;

/// All worktrees linked to the repository.
///
/// error - The error if one occurred.
///
/// Returns an array of `GTWorktree`s, or nil if an error occurred. A
/// repository with no linked worktrees returns an empty array.
- (NSArray<GTWorktree *> * _Nullable)worktreesWithError:(NSError **)error;

/// Looks up a linked worktree by name.
///
/// name  - The name of the worktree to look up. Cannot be nil.
/// error - The error if one occurred.
///
/// Returns the worktree, or nil if it couldn't be found (or another error
/// occurred).
- (GTWorktree * _Nullable)lookupWorktreeWithName:(NSString *)name error:(NSError **)error;
```

- [ ] **Step 4: Extend `GTRepository+Worktree.m`**

Edit `ObjectiveGit/GTRepository+Worktree.m`: add `#import "NSArray+StringArray.h"` alongside the existing imports, and add these method implementations inside `@implementation GTRepository (Worktree)`, after `addWorktreeWithName:URL:reference:error:` and before `@end`:

```objc

+ (instancetype)repositoryWithWorktree:(GTWorktree *)worktree error:(NSError **)error {
	return [[self alloc] initWithWorktree:worktree error:error];
}

- (instancetype)initWithWorktree:(GTWorktree *)worktree error:(NSError **)error {
	NSParameterAssert(worktree != nil);

	git_repository *repo;
	int gitError = git_repository_open_from_worktree(&repo, worktree.git_worktree);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to open repository for worktree %@.", worktree.name];
		return nil;
	}

	return [self initWithGitRepository:repo];
}

- (NSArray<GTWorktree *> *)worktreesWithError:(NSError **)error {
	git_strarray names;
	int gitError = git_worktree_list(&names, self.git_repository);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to list worktrees."];
		return nil;
	}

	NSArray<NSString *> *worktreeNames = [NSArray git_arrayWithStrarray:names];
	git_strarray_dispose(&names);

	NSMutableArray<GTWorktree *> *worktrees = [NSMutableArray arrayWithCapacity:worktreeNames.count];
	for (NSString *name in worktreeNames) {
		GTWorktree *worktree = [self lookupWorktreeWithName:name error:error];
		if (worktree == nil) return nil;

		[worktrees addObject:worktree];
	}

	return worktrees;
}

- (GTWorktree *)lookupWorktreeWithName:(NSString *)name error:(NSError **)error {
	NSParameterAssert(name != nil);

	git_worktree *worktree;
	int gitError = git_worktree_lookup(&worktree, self.git_repository, name.UTF8String);
	if (gitError != GIT_OK) {
		if (error != NULL) *error = [NSError git_errorFor:gitError description:@"Failed to look up worktree %@.", name];
		return nil;
	}

	return [[GTWorktree alloc] initWithGitWorktree:worktree];
}
```

- [ ] **Step 5: Run the build/tests to confirm they pass**

```bash
flowdeck test 2>&1 | tail -100
```

(A FlowDeck project config is already saved for this worktree — `flowdeck test` uses it with no flags needed. Raw `xcodebuild` is blocked in this environment.)

Expected: PASS — full `GTRepositoryWorktreeSpec` (10 examples total) plus the full existing suite green.

- [ ] **Step 6: Commit**

```bash
git add ObjectiveGit/GTRepository+Worktree.h ObjectiveGit/GTRepository+Worktree.m ObjectiveGitTests/GTRepository+WorktreeSpec.m
git commit -m "Add worktree lookup, listing, and repository-opening to GTRepository+Worktree"
```

---

## Self-Review Notes

- **Spec coverage:** Purpose (create/list/inspect/remove/open) → Tasks 1–3. `GTWorktreePruneOptions` bitmask → Task 1. `isWorktree`/`commonGitDirectoryURL` → Task 2. `addWorktreeWithName:URL:reference:error:` (both nil and explicit reference) → Task 2. `worktreesWithError:`/`lookupWorktreeWithName:error:`/`repositoryWithWorktree:error:` → Task 3. No `fdescribe`/`fit`/`fcontext` anywhere above. No new fixture-zip content used (fresh temp dirs + existing `blankFixtureRepository`/`bareFixtureRepository`).
- **Type consistency:** `GTWorktree.git_worktree`, `GTRepository.git_repository`, `GTReference.git_reference` inner-pointer accessor names match their existing/introduced declarations exactly across all three tasks. `GTWorktreePruneOptions` type used identically in Task 1's declaration and its own tests.
- **Review Focus:** all five items map to a specific test in the plan (see "Review Focus" section above for the mapping).

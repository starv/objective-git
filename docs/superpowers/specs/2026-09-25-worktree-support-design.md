# objective-git worktree support — design

## Purpose

A specific app built on objective-git needs to manage git worktrees: create a linked worktree (optionally against a specific branch/ref), list/inspect existing worktrees, open one, and remove/prune worktrees that are no longer needed. objective-git currently has no worktree API at all.

## Context (from investigation)

- No existing worktree code in objective-git. Greenfield feature.
- A prior attempt exists as GitHub PR #642 (`GTWorktree` + `GTRepository+Worktree`, by tiennou/Etienne Samson, opened 2018). It is explicitly an untested work-in-progress, is now `CONFLICTING` against master, bundles unrelated nullability-annotation changes across ~10 files (including removing a `nullable` annotation from `gitDirectoryURL`, a public API behavior change), left a stray `fdescribe` in its Quick spec (would silently disable the rest of the suite), and predates `git_worktree_add_options.ref`/`checkout_options` support in libgit2 — so it has no way to select a branch/ref when creating a worktree, and no `git_worktree_prune` wrapper at all. Verdict: useful as prior art for the overall shape, not a base to rebase from.
- Vendored libgit2 is pinned at v1.9.7 (`External/libgit2`) and already exposes the full modern worktree API needed here — no libgit2 bump required: `git_worktree_list`, `git_worktree_lookup`, `git_worktree_open_from_repository`, `git_worktree_free`, `git_worktree_validate`, `git_worktree_add_options_init`/`git_worktree_add` (with `lock`, `checkout_existing`, `ref`, `checkout_options` fields), `git_worktree_lock`/`unlock`/`is_locked`, `git_worktree_name`/`path`, `git_worktree_prune_options_init`/`is_prunable`/`prune`.
- Codebase convention: wrapper classes live flat in `ObjectiveGit/` as `GT<Concept>.h`/`.m` pairs mirroring a libgit2 type. `GTRepository` functionality that doesn't belong in the base file is split into categories (`GTRepository+References`, `+Merging`, `+Committing`, `+Stashing`, `+Status`, `+Reset`, `+Attributes`, `+RemoteOperations`, `+Blame`, `+Pull`). `GTSubmodule` is the closest existing analog to a new `GTWorktree`: owns a raw `git_<type> *` handle stored as a private `readonly` property, exposed via an accessor marked `__attribute__((objc_returns_inner_pointer))`, freed in `-dealloc`, constructed only by its parent (never `init` directly — `init` is `NS_UNAVAILABLE`), with a `NS_DESIGNATED_INITIALIZER` taking the libgit2 handle.
- Enumeration convention: iterator-based libgit2 APIs (like `git_branch_iterator`) are fully drained into an `NSArray` before returning; `git_worktree_list` returns a `git_strarray`, which maps the same way — loop the strarray, resolve each name via `git_worktree_lookup`, collect into an array.
- Error handling convention: every fallible call takes a trailing `NSError **error` and wraps libgit2 error codes via `[NSError git_errorFor:gitError description:...]`.
- Testing convention: Quick + Nimble BDD specs in `ObjectiveGitTests/`, named `GT<Class>Spec.m`, using fixture repos unzipped per-example via `QuickSpec+GTFixtures.h` (`-blankFixtureRepository`, `-bareFixtureRepository`, etc.) and `-tempDirectoryFileURL` for scratch paths.

## Scope decisions (confirmed with user)

- **Motivation**: a specific app needs this (not general API completeness, not specifically finishing PR #642).
- **In scope**: create a worktree (with branch/ref selection), list/inspect worktrees, remove/prune worktrees, open a worktree as its own `GTRepository`.
- **Out of scope for this pass**: locking/unlocking worktrees, querying another worktree's HEAD without opening it (`git_repository_head_for_worktree` / detached-HEAD-by-name), and general repository-workdir relocation (`git_repository_set_workdir`). All three are straightforward to add later following the same pattern if a need arises.

## Architecture

Two new units, following the existing `GTSubmodule`/`GTRepository+<Category>` split:

1. **`GTWorktree`** (new class) — owns and frees a `git_worktree *`. Constructed only by `GTRepository`.
2. **`GTRepository (Worktree)`** (new category, `GTRepository+Worktree.h`/`.m`) — creation, lookup, and listing of `GTWorktree` instances, plus worktree-awareness on `GTRepository` itself (`isWorktree`, `commonGitDirectoryURL`, opening a `GTRepository` from a `GTWorktree`).

Both link into `ObjectiveGitFramework.xcodeproj` the same way every other `GT*`/`GTRepository+*` file does today (added to the relevant target's Sources build phase; `ObjectiveGit.h` umbrella header gets a new `#import`).

## Components

### `GTWorktree.h`/`.m`

```objc
@interface GTWorktree : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSURL *worktreeURL;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype _Nullable)initWithGitWorktree:(git_worktree *)worktree NS_DESIGNATED_INITIALIZER;

- (git_worktree *)git_worktree __attribute__((objc_returns_inner_pointer));

- (BOOL)isValidWithError:(NSError **)error;
- (BOOL)isPrunableWithOptions:(GTWorktreePruneOptions)options error:(NSError **)error;
- (BOOL)pruneWithOptions:(GTWorktreePruneOptions)options error:(NSError **)error;

@end
```

- `name`/`worktreeURL` wrap `git_worktree_name`/`git_worktree_path` (computed on access, no caching — matches `GTSubmodule.name` etc.).
- `GTWorktreePruneOptions` is a new `NS_OPTIONS(NSUInteger, ...)` bitmask mirroring `git_worktree_prune_t` (`GTWorktreePruneOptionsValid`, `GTWorktreePruneOptionsLocked`, `GTWorktreePruneOptionsWorkingTree`), replacing PR #642's stringly-typed `NSDictionary` approach with a typed one consistent with how the rest of the codebase models libgit2 bit flags.
- `-dealloc` calls `git_worktree_free`.

### `GTRepository+Worktree.h`/`.m`

```objc
@interface GTRepository (Worktree)

@property (nonatomic, readonly, getter=isWorktree) BOOL worktree;
@property (nonatomic, readonly, copy) NSURL *commonGitDirectoryURL;

+ (instancetype _Nullable)repositoryWithWorktree:(GTWorktree *)worktree error:(NSError **)error;
- (instancetype _Nullable)initWithWorktree:(GTWorktree *)worktree error:(NSError **)error;

- (NSArray<GTWorktree *> * _Nullable)worktreesWithError:(NSError **)error;
- (GTWorktree * _Nullable)lookupWorktreeWithName:(NSString *)name error:(NSError **)error;
- (GTWorktree * _Nullable)addWorktreeWithName:(NSString *)name
                                           URL:(NSURL *)worktreeURL
                                     reference:(GTReference * _Nullable)reference
                                         error:(NSError **)error;

@end
```

- `isWorktree` wraps `git_repository_is_worktree` — answerable by any `GTRepository`, not just ones opened via `GTWorktree`.
- `commonGitDirectoryURL` wraps `git_repository_commondir`.
- `+repositoryWithWorktree:error:`/`-initWithWorktree:error:` wrap `git_repository_open_from_worktree`, giving a fully-functional `GTRepository` for operating inside the worktree (commit, status, checkout, etc. all work unmodified since it's a normal `GTRepository`).
- `-worktreesWithError:` loops `git_worktree_list`'s `git_strarray` and resolves each name via `git_worktree_lookup`, returning full `GTWorktree` objects (not just names) — this is the "list/inspect" entry point.
- `-lookupWorktreeWithName:error:` wraps `git_worktree_lookup` directly for the single-name case.
- `-addWorktreeWithName:URL:reference:error:` wraps `git_worktree_add_options_init`/`git_worktree_add`. `reference` maps to `git_worktree_add_options.ref`: `nil` uses libgit2's default (auto-create a branch named after the worktree from current HEAD); a non-nil `GTReference` checks out that specific existing branch into the new worktree. `lock` and `checkout_existing` fields are left at their zero/default values — not needed for this scope.

## Error handling

No new pattern: every fallible method takes a trailing `NSError **error` and produces errors via `[NSError git_errorFor:gitError description:...]`, exactly as the rest of the codebase does.

## Testing

- `GTWorktreeSpec.m` — exercise `-isValidWithError:`, `-isPrunableWithOptions:error:`, `-pruneWithOptions:error:` against a worktree created in a `beforeEach`.
- `GTRepository+WorktreeSpec.m` — exercise `-addWorktreeWithName:URL:reference:error:` (both with `nil` reference and with an explicit branch `GTReference`), `-worktreesWithError:`, `-lookupWorktreeWithName:error:`, `isWorktree`, `commonGitDirectoryURL`, and `+repositoryWithWorktree:error:` (confirming the resulting `GTRepository` reports `isWorktree == YES` and can run normal repository operations).
- Both specs use Quick/Nimble, following existing spec structure and naming. Worktree targets use `-tempDirectoryFileURL` (existing fixture helper); source repos use `-blankFixtureRepository` or `-bareFixtureRepository` as appropriate — no new fixture zip content needed since worktrees are created fresh in each test rather than needing to ship a pre-existing worktree layout in `fixtures.zip`.
- No `fdescribe`/`fit`/`fcontext` left in committed specs (the mistake that shipped in PR #642).

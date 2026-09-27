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

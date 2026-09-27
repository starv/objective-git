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

@end

NS_ASSUME_NONNULL_END

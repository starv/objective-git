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

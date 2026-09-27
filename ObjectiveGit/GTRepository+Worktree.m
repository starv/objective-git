//
//  GTRepository+Worktree.m
//  ObjectiveGitFramework
//

#import "GTRepository+Worktree.h"
#import "GTWorktree.h"
#import "GTReference.h"
#import "NSError+Git.h"
#import "NSArray+StringArray.h"

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

@end

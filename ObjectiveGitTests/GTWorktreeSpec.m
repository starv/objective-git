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

	// Create an initial commit so the repository doesn't have an unborn branch
	GTTreeBuilder *builder = [[GTTreeBuilder alloc] initWithTree:nil repository:repo error:NULL];
	expect(builder).notTo(beNil());

	GTTree *tree = [builder writeTree:NULL];
	expect(tree).notTo(beNil());

	GTCommit *initialCommit = [repo createCommitWithTree:tree message:@"Initial commit" parents:nil updatingReferenceNamed:@"refs/heads/master" error:NULL];
	expect(initialCommit).notTo(beNil());

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
	NSString *standardizedExpectedPath = [worktreeURL.path stringByResolvingSymlinksInPath];
	NSString *standardizedActualPath = [worktree.worktreeURL.path stringByResolvingSymlinksInPath];
	expect(standardizedActualPath).to(equal(standardizedExpectedPath));
});

it(@"should be valid immediately after creation", ^{
	__block NSError *error = nil;
	expect(@([worktree isValidWithError:&error])).to(beTruthy());
	expect(error).to(beNil());
});

it(@"should not be prunable while its working tree is still checked out and valid", ^{
	__block NSError *error = nil;
	expect(@([worktree isPrunableWithOptions:0 error:&error])).to(beFalsy());
	expect(error).to(beNil());
});

it(@"should be prunable when the valid and working-tree flags are forced", ^{
	__block NSError *error = nil;
	GTWorktreePruneOptions options = GTWorktreePruneOptionsValid | GTWorktreePruneOptionsWorkingTree;
	expect(@([worktree isPrunableWithOptions:options error:&error])).to(beTruthy());
	expect(error).to(beNil());
});

it(@"should fail to prune while its working tree is still checked out and valid", ^{
	__block NSError *error = nil;
	expect(@([worktree pruneWithOptions:0 error:&error])).to(beFalsy());
	expect(error).notTo(beNil());
});

it(@"should prune successfully when the valid and working-tree flags are forced", ^{
	__block NSError *error = nil;
	GTWorktreePruneOptions options = GTWorktreePruneOptionsValid | GTWorktreePruneOptionsWorkingTree;
	expect(@([worktree pruneWithOptions:options error:&error])).to(beTruthy());
	expect(error).to(beNil());
});

afterEach(^{
	[self tearDown];
});

QuickSpecEnd

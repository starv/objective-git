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
		// Normalize paths for comparison to handle macOS symlink resolution
		expect(worktree.worktreeURL.path.stringByResolvingSymlinksInPath).to(equal(worktreeURL.path.stringByResolvingSymlinksInPath));

		GTRepository *worktreeRepo = [GTRepository repositoryWithURL:worktreeURL error:&error];
		expect(worktreeRepo).notTo(beNil());
		expect(@(worktreeRepo.isWorktree)).to(beTruthy());
	});

	it(@"should check out the given reference into the new worktree", ^{
		NSError *error = nil;
		GTReference *packedRef = [repo lookUpReferenceWithName:@"refs/heads/packed" error:&error];
		expect(packedRef).notTo(beNil());
		expect(error).to(beNil());

		GTWorktree *worktree = [repo addWorktreeWithName:@"from-packed" URL:worktreeURL reference:packedRef error:&error];
		expect(worktree).notTo(beNil());
		expect(error).to(beNil());

		GTRepository *worktreeRepo = [GTRepository repositoryWithURL:worktreeURL error:&error];
		expect(worktreeRepo).notTo(beNil());

		GTReference *worktreeHead = [worktreeRepo headReferenceWithError:&error];
		expect(worktreeHead.name).to(equal(@"refs/heads/packed"));
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
		// Normalize paths for comparison to handle macOS symlink resolution
		expect(found.worktreeURL.path.stringByResolvingSymlinksInPath).to(equal(worktreeURL.path.stringByResolvingSymlinksInPath));
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

afterEach(^{
	[self tearDown];
});

QuickSpecEnd

//
//  QuickSpec+GTFixtures.m
//  ObjectiveGitFramework
//
//  Created by Josh Abernathy on 3/22/13.
//  Copyright (c) 2013 GitHub, Inc. All rights reserved.
//

#import "QuickSpec+GTFixtures.h"

#import <errno.h>
#import <stdio.h>

@import ObjectiveC;
@import ObjectiveGit;
@import ZipArchive;

static const NSInteger FixturesErrorUnzipFailed = 666;

static NSString * const FixturesErrorDomain = @"com.objectivegit.Fixtures";

@interface QuickSpec (Fixtures)

@property (nonatomic, readonly, copy) NSString *repositoryFixturesPath;
@property (nonatomic, copy) NSString *tempDirectoryPath;

- (void)ensureCleanRepositoryCacheAtPath:(NSString *)cleanRepositoryPath fromZipAtPath:(NSString *)zippedRepositoriesPath;

@end

@implementation QuickSpec (Fixtures)

#pragma mark Properties

- (NSString *)tempDirectoryPath {
	NSString *path = objc_getAssociatedObject(self, _cmd);
	if (path != nil) return path;

	[self setUpTempDirectoryPath];
	return objc_getAssociatedObject(self, _cmd);
}

- (void)setTempDirectoryPath:(NSString *)path {
	objc_setAssociatedObject(self, @selector(tempDirectoryPath), path, OBJC_ASSOCIATION_COPY);
}

- (NSURL *)tempDirectoryFileURL {
	return [NSURL fileURLWithPath:self.tempDirectoryPath isDirectory:YES];
}

- (NSString *)repositoryFixturesPath {
	return [self.tempDirectoryPath stringByAppendingPathComponent:@"repositories"];
}

#pragma mark Setup/Teardown

- (void)tearDown {
	[super tearDown];

	[self cleanUp];
}

- (void)cleanUp {
	NSString *path = self.tempDirectoryPath;
	if (path == nil) return;

	[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
	self.tempDirectoryPath = nil;
}

#pragma mark Fixtures

- (NSString *)rootTempDirectory {
	return [NSTemporaryDirectory() stringByAppendingPathComponent:@"com.libgit2.objectivegit"];
}

- (void)setUpTempDirectoryPath {
	self.tempDirectoryPath = [self.rootTempDirectory stringByAppendingPathComponent:NSProcessInfo.processInfo.globallyUniqueString];

	NSError *error = nil;
	BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:self.tempDirectoryPath withIntermediateDirectories:YES attributes:nil error:&error];
	XCTAssertTrue(success, @"Couldn't create the temp fixtures directory at %@: %@", self.tempDirectoryPath, error);
}

- (void)setUpRepositoryFixtureIfNeeded:(NSString *)repositoryName {
	NSString *path = [self.repositoryFixturesPath stringByAppendingPathComponent:repositoryName];

	BOOL isDirectory = NO;
	if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) return;

	NSError *error = nil;
	BOOL success = [NSFileManager.defaultManager createDirectoryAtPath:self.repositoryFixturesPath withIntermediateDirectories:YES attributes:nil error:&error];
	XCTAssertTrue(success, @"Couldn't create the repository fixtures directory at %@: %@", self.repositoryFixturesPath, error);

	NSString *zippedRepositoriesPath = [[NSBundle bundleForClass:self.class] pathForResource:@"fixtures" ofType:@"zip"];

	// `clean_repository` is a cache shared by every spec instance across the
	// whole test run, used so the fixtures zip is only unzipped once instead
	// of once per spec. With the scheme's "Execute in parallel (if possible)"
	// test setting enabled, Xcode spawns several independent `xctest` worker
	// processes that each run a subset of the spec classes concurrently --
	// but NSTemporaryDirectory() (and therefore rootTempDirectory) resolves
	// to the same path in every one of them, so every worker shares this one
	// `clean_repository` directory.
	NSString *cleanRepositoryPath = [self.rootTempDirectory stringByAppendingPathComponent:@"clean_repository"];
	[self ensureCleanRepositoryCacheAtPath:cleanRepositoryPath fromZipAtPath:zippedRepositoriesPath];

	success = [[NSFileManager defaultManager] copyItemAtPath:[cleanRepositoryPath stringByAppendingPathComponent:repositoryName] toPath:path error:&error];
	XCTAssertTrue(success, @"Couldn't copy directory %@", error);
}

- (void)ensureCleanRepositoryCacheAtPath:(NSString *)cleanRepositoryPath fromZipAtPath:(NSString *)zippedRepositoriesPath {
	if ([NSFileManager.defaultManager fileExistsAtPath:cleanRepositoryPath isDirectory:nil]) return;

	// Populate the shared cache by unzipping into a private, uniquely-named
	// staging directory first, then publishing it into `clean_repository`
	// with a single atomic rename(2) (both paths live under the same
	// NSTemporaryDirectory()-based filesystem, so the rename is atomic).
	//
	// This guarantees every worker process only ever observes
	// `clean_repository` in one of two states -- entirely absent, or fully
	// populated -- which closes two related hazards:
	//   1. The cross-process race this cache originally hit: multiple
	//      workers' unzip/copy calls interleaving against the *same*
	//      destination directory, so one worker's in-progress write could
	//      transiently remove/replace a subdirectory (e.g. "testrepo.git",
	//      "Test_App") at the exact moment another worker's
	//      copyItemAtPath: tried to read it, producing intermittent
	//      "no such file or directory" failures.
	//   2. A subtler variant of the same problem: even the simple
	//      fileExistsAtPath: check above could observe a directory *while*
	//      another worker was still unzipping into it, i.e. a half-populated
	//      cache that looks "done" but isn't.
	// An earlier version of this fix scoped the cache directory by process
	// ID instead, which avoided the race but leaked one ~37MB cache
	// directory per parallel worker per test run with nothing to ever clean
	// them up. Publishing atomically into a single shared path fixes the
	// race without any per-run accumulation.
	NSString *stagingPath = [cleanRepositoryPath stringByAppendingFormat:@".%@", NSProcessInfo.processInfo.globallyUniqueString];

	NSError *error = nil;
	BOOL success = [self unzipFromArchiveAtPath:zippedRepositoriesPath intoDirectory:stagingPath error:&error];
	XCTAssertTrue(success, @"Couldn't unzip fixture from %@ to %@: %@", zippedRepositoriesPath, stagingPath, error);
	if (!success) {
		// Don't publish a partial/broken staging directory into the shared
		// cache -- that would poison every subsequent test run that reuses
		// this persistent cache location. Clean up our staging directory and
		// bail out before the rename below.
		[NSFileManager.defaultManager removeItemAtPath:stagingPath error:NULL];
		return;
	}

	if (rename(stagingPath.fileSystemRepresentation, cleanRepositoryPath.fileSystemRepresentation) != 0) {
		int renameErrno = errno;

		// EEXIST/ENOTEMPTY means another worker already published
		// `clean_repository` first -- the shared cache is populated either
		// way, so just discard our now-redundant staging copy. Any other
		// failure is a genuine, unexpected problem worth surfacing.
		if (renameErrno != EEXIST && renameErrno != ENOTEMPTY) {
			XCTFail(@"Couldn't publish fixture cache from %@ to %@: %s", stagingPath, cleanRepositoryPath, strerror(renameErrno));
		}

		[NSFileManager.defaultManager removeItemAtPath:stagingPath error:NULL];
	}
}

- (NSString *)pathForFixtureRepositoryNamed:(NSString *)repositoryName {
	[self setUpRepositoryFixtureIfNeeded:repositoryName];

	return [self.repositoryFixturesPath stringByAppendingPathComponent:repositoryName];
}

- (BOOL)unzipFromArchiveAtPath:(NSString *)zipPath intoDirectory:(NSString *)destinationPath error:(NSError **)error {
	BOOL success = [SSZipArchive unzipFileAtPath:zipPath toDestination:destinationPath overwrite:YES password:nil error:error];

	if (!success) {
		NSLog(@"Unzip failed");
		return NO;
	}

	return YES;
}

#pragma mark API

- (GTRepository *)fixtureRepositoryNamed:(NSString *)name {
	NSURL *url = [NSURL fileURLWithPath:[self pathForFixtureRepositoryNamed:name]];
	GTRepository *repository = [[GTRepository alloc] initWithURL:url error:NULL];
	XCTAssertNotNil(repository, @"Couldn't create a repository for %@", name);
	return repository;
}

- (GTRepository *)testAppFixtureRepository {
	return [self fixtureRepositoryNamed:@"Test_App"];
}

- (GTRepository *)testAppForkFixtureRepository {
	return [self fixtureRepositoryNamed:@"Test_App_fork"];
}

- (GTRepository *)testUnicodeFixtureRepository {
	return [self fixtureRepositoryNamed:@"unicode-files-repo"];
}

- (GTRepository *)bareFixtureRepository {
	return [self fixtureRepositoryNamed:@"testrepo.git"];
}

- (GTRepository *)submoduleFixtureRepository {
	return [self fixtureRepositoryNamed:@"repo-with-submodule"];
}

- (GTRepository *)conflictedFixtureRepository {
	return [self fixtureRepositoryNamed:@"conflicted-repo"];
}

- (GTRepository *)blankFixtureRepository {
	NSURL *repoURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"blank-repo"];

	GTRepository *repository = [GTRepository initializeEmptyRepositoryAtFileURL:repoURL options:nil error:NULL];
	XCTAssertNotNil(repository, @"Couldn't create a blank repository");
	return repository;
}

- (GTRepository *)blankBareFixtureRepository {
	NSURL *repoURL = [self.tempDirectoryFileURL URLByAppendingPathComponent:@"blank-repo.git"];
	NSDictionary *options = @{
		GTRepositoryInitOptionsFlags: @(GTRepositoryInitBare | GTRepositoryInitCreatingRepositoryDirectory)
	};

	GTRepository *repository = [GTRepository initializeEmptyRepositoryAtFileURL:repoURL options:options error:NULL];
	XCTAssertNotNil(repository, @"Couldn't create a blank repository");
	return repository;
}

#pragma mark Properties

- (NSBundle *)mainTestBundle {
	return [NSBundle bundleForClass:self.class];
}

@end

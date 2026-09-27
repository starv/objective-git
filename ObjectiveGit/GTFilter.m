//
//  GTFilter.m
//  ObjectiveGitFramework
//
//  Created by Josh Abernathy on 2/14/14.
//  Copyright (c) 2014 GitHub, Inc. All rights reserved.
//

#import "GTFilter.h"
#import "GTRepository.h"
#import "NSError+Git.h"
#import "GTFilterSource.h"

#import "git2/errors.h"
#import "git2/sys/errors.h"
#import "git2/sys/filter.h"

#import <string.h>

NSString * const GTFilterErrorDomain = @"GTFilterErrorDomain";

const NSInteger GTFilterErrorNameAlreadyRegistered = -1;

static NSMutableDictionary *GTFiltersNameToRegisteredFilters = nil;
static NSMutableDictionary *GTFiltersGitFilterToRegisteredFilters = nil;

@interface GTFilter () {
	git_filter _filter;
}

@property (nonatomic, readonly, copy) NSString *name;

@property (nonatomic, readonly, copy) NSData * (^applyBlock)(void **payload, NSData *from, GTFilterSource *source, BOOL *applied);

@end

@implementation GTFilter

#pragma mark Lifecycle

+ (void)initialize {
	if (self != GTFilter.class) return;

	GTFiltersNameToRegisteredFilters = [[NSMutableDictionary alloc] init];
	GTFiltersGitFilterToRegisteredFilters = [[NSMutableDictionary alloc] init];
}

- (instancetype)init {
	NSAssert(NO, @"Call to an unavailable initializer.");
	return nil;
}

- (instancetype)initWithName:(NSString *)name attributes:(NSString *)attributes applyBlock:(NSData * (^)(void **payload, NSData *from, GTFilterSource *source, BOOL *applied))applyBlock {
	NSParameterAssert(name != nil);
	NSParameterAssert(applyBlock != NULL);

	self = [super init];
	if (self == nil) return nil;

	_filter.version = GIT_FILTER_VERSION;
	_filter.attributes = attributes.UTF8String;
	_filter.apply = &GTFilterApply;

	_name = [name copy];
	_applyBlock = [applyBlock copy];

	return self;
}

#pragma mark NSObject

- (BOOL)isEqual:(GTFilter *)object {
	if (object == self) return YES;
	if (![object isKindOfClass:self.class]) return NO;

	return [object.name isEqual:object.name];
}

- (NSUInteger)hash {
	return self.name.hash;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"<%@: %p> name: %@", self.class, self, self.name];
}

#pragma mark Properties

static int GTFilterInit(git_filter *filter) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	self.initializeBlock();
	return 0;
}

static void GTFilterShutdown(git_filter *filter) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	self.shutdownBlock();
}

static int GTFilterCheck(git_filter *filter, void **payload, const git_filter_source *src, const char **attr_values) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	GTFilterSource *source = [[GTFilterSource alloc] initWithGitFilterSource:src];
	NSCAssert(source != nil, @"Unexpected nil filter source");
	BOOL accept = self.checkBlock(payload, source, attr_values);
	return accept ? 0 : GIT_PASSTHROUGH;
}

static int GTFilterApply(git_filter *filter, void **payload, git_buf *to, const git_buf *from, const git_filter_source *src) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	NSData *fromData = [NSData dataWithBytesNoCopy:from->ptr length:from->size freeWhenDone:NO];
	BOOL applied = YES;
	NSData *toData = self.applyBlock(payload, fromData, [[GTFilterSource alloc] initWithGitFilterSource:src], &applied);
	if (!applied) return GIT_PASSTHROUGH;

	// `git_buf` is output-only in libgit2 1.x, and `git_buf_set` no longer
	// exists in the public API. Populate `to` directly with an allocation
	// that `git_buf_dispose` (which frees `ptr` with the default allocator)
	// can safely release, and NUL-terminate per the documented `git_buf`
	// contract even though the content may itself contain embedded NULs.
	//
	// `to` is not guaranteed to arrive empty: in libgit2 1.9's legacy
	// `git_filter_apply_fn` path, the buffer backing `to` is reused scratch
	// storage (e.g. a filter session's temp buffer, see
	// src/libgit2/filter.c) that's cleared but *not freed* between filter
	// invocations, so `to->ptr`/`to->reserved` can already point at a live
	// allocation here. Reuse/grow that allocation with `realloc` instead of
	// leaking it, mirroring what `git_buf_set` used to do.
	//
	// Critically, `to->reserved == 0` does NOT imply `to->ptr == NULL`:
	// libgit2's `git_str_clear` (src/util/str.c) resets an unallocated
	// buffer's `ptr` to its static empty-string sentinel (`git_str__initstr`)
	// rather than NULL, while leaving `reserved` at 0. That sentinel is a
	// non-NULL pointer that was never heap-allocated, so passing it to
	// `realloc` is undefined behavior (observed to abort on macOS). Only
	// `to->reserved > 0` guarantees `to->ptr` is a real heap allocation safe
	// to hand to `realloc`; otherwise pass NULL, which `realloc` treats as a
	// fresh `malloc`.
	size_t length = toData.length;
	char *existingBuffer = (to->reserved > 0) ? to->ptr : NULL;
	char *buffer = realloc(existingBuffer, length + 1);
	if (buffer == NULL) {
		git_error_set_oom();
		return GIT_ERROR;
	}

	memcpy(buffer, toData.bytes, length);
	buffer[length] = '\0';

	to->ptr = buffer;
	to->size = length;
	to->reserved = length + 1;

	return 0;
}

static void GTFilterCleanup(git_filter *filter, void *payload) {
	GTFilter *self = GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:filter]];
	self.cleanupBlock(payload);
}

- (void)setInitializeBlock:(void (^)(void))initializeBlock {
	_filter.initialize = (initializeBlock != nil ? &GTFilterInit : NULL);
	_initializeBlock = [initializeBlock copy];
}

- (void)setShutdownBlock:(void (^)(void))shutdownBlock {
	_filter.shutdown = (shutdownBlock != nil ? &GTFilterShutdown : NULL);
	_shutdownBlock = [shutdownBlock copy];
}

- (void)setCheckBlock:(BOOL (^)(void **, GTFilterSource *, const char **))checkBlock {
	_filter.check = (checkBlock != nil ? &GTFilterCheck : NULL);
	_checkBlock = [checkBlock copy];
}

- (void)setCleanupBlock:(void (^)(void *))cleanupBlock {
	_filter.cleanup = (cleanupBlock != nil ? &GTFilterCleanup : NULL);
	_cleanupBlock = [cleanupBlock copy];
}

#pragma mark Registration

- (BOOL)registerWithPriority:(int)priority error:(NSError **)error {
	if (GTFiltersNameToRegisteredFilters[self.name] != nil) {
		if (error != NULL) {
			NSString *description = [NSString stringWithFormat:NSLocalizedString(@"A filter named \"%@\" has already been registered", @""), self.name];
			NSString *recoverySuggestion = NSLocalizedString(@"Unregister the existing filter first.", @"");
			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: description,
				NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion,
			};
			*error = [NSError errorWithDomain:GTFilterErrorDomain code:GTFilterErrorNameAlreadyRegistered userInfo:userInfo];
		}

		return NO;
	}

	int result = git_filter_register(self.name.UTF8String, &_filter, GIT_FILTER_DRIVER_PRIORITY + priority);
	if (result != GIT_OK) {
		if (error != NULL) {
			*error = [NSError git_errorFor:result description:@"Failed to register filter: %@", self.name];
		}

		return NO;
	}

	GTFiltersNameToRegisteredFilters[self.name] = self;
	GTFiltersGitFilterToRegisteredFilters[[NSValue valueWithPointer:&_filter]] = self;

	return YES;
}

- (BOOL)unregister:(NSError **)error {
	int result = git_filter_unregister(self.name.UTF8String);
	if (result != GIT_OK) {
		if (error != NULL) {
			*error = [NSError git_errorFor:result description:@"Failed to unregister filter: %@", self.name];
		}

		return NO;
	}

	[GTFiltersNameToRegisteredFilters removeObjectForKey:self.name];
	[GTFiltersGitFilterToRegisteredFilters removeObjectForKey:[NSValue valueWithPointer:&_filter]];

	return YES;
}

#pragma mark Lookup

+ (GTFilter *)filterForName:(NSString *)name {
	NSParameterAssert(name != nil);

	return GTFiltersNameToRegisteredFilters[name];
}

@end

//
//  NSDataGitSpec.m
//  ObjectiveGitFramework
//
//  Created by Justin Spahr-Summers on 2014-06-27.
//  Copyright (c) 2014 GitHub, Inc. All rights reserved.
//

@import ObjectiveGit;
@import Nimble;
@import Quick;

#import "QuickSpec+GTFixtures.h"

QuickSpecBegin(NSDataGit)

const void *testData = "hello world";
const size_t testDataSize = strlen(testData) + 1;

describe(@"+git_dataWithBuffer:", ^{
	__block git_buf buffer;

	beforeEach(^{
		// libgit2 1.x's `git_buf` is output-only, so there's no `git_buf_set`
		// to build one from constant data. Simulate what libgit2 itself would
		// hand back: a heap-allocated, owned buffer.
		buffer = (git_buf)GIT_BUF_INIT;

		void *ptr = malloc(testDataSize);
		memcpy(ptr, testData, testDataSize);

		buffer.ptr = ptr;
		buffer.reserved = testDataSize;
		buffer.size = testDataSize;

		expect([NSValue valueWithPointer:buffer.ptr]).notTo(equal([NSValue valueWithPointer:NULL]));
		expect([NSValue valueWithPointer:buffer.ptr]).notTo(equal([NSValue valueWithPointer:testData]));
		expect(@(buffer.size)).to(equal(@(testDataSize)));
		expect(@(buffer.reserved)).to(beGreaterThanOrEqualTo(@(testDataSize)));
	});

	afterEach(^{
		git_buf_dispose(&buffer);
	});

	it(@"should create matching NSData", ^{
		NSData *data = [NSData git_dataWithBuffer:&buffer];
		expect(data).notTo(beNil());

		expect(@(data.length)).to(equal(@(testDataSize)));
		expect(@(memcmp(data.bytes, testData, testDataSize))).to(equal(@0));
	});

	it(@"should invalidate the buffer", ^{
		[NSData git_dataWithBuffer:&buffer];

		expect(@(buffer.size)).to(equal(@0));
		expect(@(buffer.reserved)).to(equal(@0));
		expect([NSValue valueWithPointer:buffer.ptr]).to(equal([NSValue valueWithPointer:NULL]));
	});
});

describe(@"git_buf", ^{
	__block NSData *data;

	beforeEach(^{
		data = [NSData dataWithBytes:testData length:testDataSize];
		expect(data).notTo(beNil());
	});

	it(@"should return a constant buffer of the data's bytes", ^{
		git_buf buffer = data.git_buf;
		expect([NSValue valueWithPointer:buffer.ptr]).to(equal([NSValue valueWithPointer:data.bytes]));
		expect(@(buffer.size)).to(equal(@(data.length)));
		expect(@(buffer.reserved)).to(equal(@0));
	});
});

afterEach(^{
	[self tearDown];
});

QuickSpecEnd

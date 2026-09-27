//
//  NSData+Git.m
//

#import "NSData+Git.h"
#import "NSError+Git.h"

#import "git2/blob.h"
#import "git2/errors.h"

#import <string.h>

@implementation NSData (Git)

+ (NSData *)git_dataWithOid:(git_oid *)oid {
    return [NSData dataWithBytes:oid length:sizeof(git_oid)];
}

- (BOOL)git_getOid:(git_oid *)oid error:(NSError **)error {
    if ([self length] != sizeof(git_oid)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:GTGitErrorDomain 
                                         code:GIT_ERROR_INVALID
                                     userInfo:
                      [NSDictionary dictionaryWithObject:@"can't extract oid from data of incorrect length" 
                                                  forKey:NSLocalizedDescriptionKey]];
        }
        return NO;
    }
    
    [self getBytes:oid length:sizeof(git_oid)];
    return YES;
}

+ (instancetype)git_dataWithBuffer:(git_buf *)buffer {
	NSCParameterAssert(buffer != NULL);

	if (buffer->size == 0) {
		// The buffer may still have allocated storage (`reserved > 0`) even
		// though it reports zero used bytes; dispose of it so we don't leak
		// libgit2-owned memory before returning the shared empty NSData.
		if (buffer->reserved > 0) git_buf_dispose(buffer);
		return [self data];
	}

	// In libgit2 1.x, `git_buf` is an output-only type: any buffer handed to
	// us by libgit2 is already dynamically allocated, so there's no need to
	// grow it defensively before taking ownership of its memory.
	NSData *data = [self dataWithBytesNoCopy:buffer->ptr length:buffer->size freeWhenDone:YES];
	*buffer = (git_buf)GIT_BUF_INIT;

	return data;
}

- (git_buf)git_buf {
	return (git_buf){ .ptr = (char *)self.bytes, .reserved = 0, .size = self.length };
}

- (BOOL)git_containsNUL {
	return memchr(self.bytes, 0, self.length) != NULL;
}

- (BOOL)git_isBinary {
	return git_blob_data_is_binary((const char *)self.bytes, self.length) > 0;
}

@end

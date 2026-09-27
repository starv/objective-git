//
//  NSData+Git.h
//

#import <Foundation/Foundation.h>
#import "git2/buffer.h"
#import "git2/oid.h"

@interface NSData (Git)

+ (NSData *)git_dataWithOid:(git_oid *)oid;
- (BOOL)git_getOid:(git_oid *)oid error:(NSError **)error;

/// Creates an NSData object that will take ownership of a libgit2 buffer.
///
/// In libgit2 1.x, `git_buf` is an output-only type: any buffer handed to
/// this method is already dynamically allocated by libgit2 (not a borrowed
/// or "reserved=0" pointer), so its memory is taken over without copying.
/// On success, the buffer's contents are reset to `GIT_BUF_INIT` and the
/// caller must not call `git_buf_dispose` on it afterwards, since ownership
/// of the underlying memory has been transferred to the returned NSData.
///
/// buffer - A libgit2-allocated buffer of data to take ownership of. This
///          argument must not be NULL.
///
/// Returns the wrapped data, or an empty NSData if the buffer is empty.
+ (instancetype)git_dataWithBuffer:(git_buf *)buffer;

/// Returns a read-only libgit2 buffer that borrows the current bytes of the
/// receiver (`reserved` is set to 0 to mark it as non-owning). This buffer
/// must never be passed to an API that could call `git_buf_dispose` on it or
/// otherwise attempt to grow/reallocate it, since its `ptr` is not memory
/// libgit2 allocated. If the length of the receiver changes after this
/// method, the behavior of the returned buffer is undefined.
- (git_buf)git_buf;

/// Checks whether the receiver's bytes contain a NUL byte.
- (BOOL)git_containsNUL;

/// Checks whether the receiver's bytes look like they contain binary data.
- (BOOL)git_isBinary;

@end

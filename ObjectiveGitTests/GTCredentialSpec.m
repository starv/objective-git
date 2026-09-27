//
//  GTCredentialSpec.m
//  ObjectiveGitFramework
//

@import Nimble;
@import Quick;

#import "GTCredential.h"
#import "git2/credential.h"

QuickSpecBegin(GTCredentialSpec)

describe(@"GTCredentialType", ^{
	it(@"maps to the same underlying libgit2 credential type values after the git_credential rename", ^{
		expect(@(GTCredentialTypeUserPassPlaintext)).to(equal(@(GIT_CREDENTIAL_USERPASS_PLAINTEXT)));
		expect(@(GTCredentialTypeSSHKey)).to(equal(@(GIT_CREDENTIAL_SSH_KEY)));
		expect(@(GTCredentialTypeSSHCustom)).to(equal(@(GIT_CREDENTIAL_SSH_CUSTOM)));
	});
});

describe(@"+credentialWithUserName:password:error:", ^{
	it(@"creates a plaintext credential", ^{
		NSError *error = nil;
		GTCredential *credential = [GTCredential credentialWithUserName:@"user" password:@"pass" error:&error];
		expect(credential).notTo(beNil());
		expect(error).to(beNil());
	});
});

QuickSpecEnd

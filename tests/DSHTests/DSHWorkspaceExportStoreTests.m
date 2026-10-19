#import <XCTest/XCTest.h>
#import <CommonCrypto/CommonDigest.h>
#import "DSHWorkspaceExportStore.h"

static NSString *DSHTestExportHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *s = [NSMutableString new];
    for (NSUInteger j=0;j<sizeof(digest);j++) [s appendFormat:@"%02x",digest[j]];
    return s;
}
@interface DSHWorkspaceExportStoreTests : XCTestCase
@property NSURL *directory;
@property DSHWorkspaceExportStore *store;
@end
@implementation DSHWorkspaceExportStoreTests
- (void)setUp {
    [super setUp];
    self.directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    self.store = [[DSHWorkspaceExportStore alloc] initWithDirectory:self.directory];
    XCTAssertNotNil(self.store);
}
- (void)tearDown { self.store=nil; [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil]; [super tearDown]; }
- (NSDictionary *)metadata:(NSData *)data {
    return @{@"request_id":@"request-1234567890",@"scope_id":@"scope-123456789012",
        @"workspace":@"/root/workspace/TapGame",@"source":@"/root/workspace/TapGame/dist/TapGame_unsigned.ipa",
        @"name":@"TapGame_unsigned.ipa",@"bytes":@(data.length),@"sha256":DSHTestExportHash(data)};
}
- (NSString *)start:(NSData *)data {
    NSError *error; NSDictionary *result=[self.store start:[self metadata:data] error:&error];
    XCTAssertNil(error); XCTAssertEqualObjects(result[@"state"],@"pending_confirmation");
    XCTAssertFalse([result[@"saved"] boolValue]); return result[@"session_id"];
}
- (void)send:(NSData *)data session:(NSString *)session {
    NSUInteger chunk=[DSHWorkspaceExportStore maximumChunkBytes];
    for (NSUInteger offset=0;offset<data.length;offset+=chunk) {
        NSData *part=[data subdataWithRange:NSMakeRange(offset,MIN(chunk,data.length-offset))];
        NSError *error; NSDictionary *result=[self.store append:part session:session offset:offset sha256:DSHTestExportHash(part) error:&error];
        XCTAssertNil(error); XCTAssertEqual([result[@"offset"] unsignedLongLongValue],offset+part.length);
    }
}
- (void)testExportLargerThanEightMiBIsExactAndSavedOnlyAfterPickerEvidence {
    NSMutableData *data=[NSMutableData dataWithLength:9*1024*1024+37];
    uint8_t *bytes=data.mutableBytes; for(NSUInteger j=0;j<data.length;j++) bytes[j]=(uint8_t)(j*31+7);
    NSString *session=[self start:data]; [self.store approve:session granted:YES]; [self send:data session:session];
    NSDictionary *ready=[self.store finish:session error:nil]; XCTAssertEqualObjects(ready[@"state"],@"ready"); XCTAssertFalse([ready[@"saved"] boolValue]);
    NSURL *file=[self.store claimForSaving:session]; XCTAssertEqualObjects(file.lastPathComponent,@"TapGame_unsigned.ipa");
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file],data);
    XCTAssertNil([self.store claimForSaving:session]);
    XCTAssertFalse([[self.store status:session error:nil][@"saved"] boolValue]);
    [self.store complete:session state:@"saved" errorCode:nil];
    XCTAssertTrue([[self.store status:session error:nil][@"saved"] boolValue]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:file.path]);
}
- (void)testNoDataAcceptedBeforeConfirmationAndDenialIsTerminal {
    NSData *data=[@"binary" dataUsingEncoding:NSUTF8StringEncoding]; NSString *session=[self start:data];
    NSError *error; XCTAssertNil([self.store append:data session:session offset:0 sha256:DSHTestExportHash(data) error:&error]);
    XCTAssertEqual(error.code,409); [self.store approve:session granted:NO];
    [self.store approve:session granted:YES];
    XCTAssertEqualObjects([self.store status:session error:nil][@"state"],@"cancelled");
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory.path error:nil].count,0u);
}
- (void)testExactDuplicateStartIsIdempotentAndChangedMetadataRefused {
    NSData *data=[@"one" dataUsingEncoding:NSUTF8StringEncoding]; NSString *session=[self start:data];
    XCTAssertEqualObjects([self.store start:[self metadata:data] error:nil][@"session_id"],session);
    NSMutableDictionary *changed=[[self metadata:data] mutableCopy]; changed[@"name"]=@"other.ipa";
    NSError *error; XCTAssertNil([self.store start:changed error:&error]); XCTAssertEqual(error.code,409);
}
- (void)testOnlyOneActiveExportAndSessionIdentifiersAreRandom {
    NSData *data=NSData.data; NSString *session=[self start:data];
    NSMutableDictionary *metadata=[[self metadata:data] mutableCopy]; metadata[@"request_id"]=@"other-request-123456";
    NSError *error; XCTAssertNil([self.store start:metadata error:&error]); XCTAssertEqual(error.code,409);
    [self.store cancel:session error:nil]; NSDictionary *other=[self.store start:metadata error:nil];
    XCTAssertNotEqualObjects(other[@"session_id"],session); XCTAssertEqual([other[@"session_id"] length],64u);
}
- (void)testLostAcknowledgementDuplicateDoesNotWriteOrHashTwice {
    NSData *data=[@"identical bytes" dataUsingEncoding:NSUTF8StringEncoding]; NSString *session=[self start:data]; [self.store approve:session granted:YES];
    [self send:data session:session];
    NSDictionary *duplicate=[self.store append:data session:session offset:0 sha256:DSHTestExportHash(data) error:nil];
    XCTAssertEqual([duplicate[@"offset"] unsignedIntegerValue],data.length);
    XCTAssertEqualObjects([self.store finish:session error:nil][@"state"],@"ready");
}
- (void)testBadChunkHashAndOutOfOrderBytesDoNotAdvanceOffset {
    NSData *data=[@"part" dataUsingEncoding:NSUTF8StringEncoding]; NSString *session=[self start:data]; [self.store approve:session granted:YES];
    NSError *error; XCTAssertNil([self.store append:data session:session offset:0 sha256:[@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0] error:&error]);
    XCTAssertEqual(error.code,400); error=nil;
    XCTAssertNil([self.store append:data session:session offset:1 sha256:DSHTestExportHash(data) error:&error]); XCTAssertEqual(error.code,409);
    XCTAssertEqual([[self.store status:session error:nil][@"offset"] unsignedIntegerValue],0u);
}
- (void)testOversizedChunkAndDeclaredFileOverflowAreRefused {
    NSData *data=[NSData dataWithBytes:"a" length:1]; NSString *session=[self start:data]; [self.store approve:session granted:YES];
    NSData *tooLarge=[NSMutableData dataWithLength:[DSHWorkspaceExportStore maximumChunkBytes]+1];
    NSError *error; XCTAssertNil([self.store append:tooLarge session:session offset:0 sha256:DSHTestExportHash(tooLarge) error:&error]); XCTAssertEqual(error.code,400);
    NSData *overflow=[NSData dataWithBytes:"ab" length:2]; error=nil;
    XCTAssertNil([self.store append:overflow session:session offset:0 sha256:DSHTestExportHash(overflow) error:&error]); XCTAssertEqual(error.code,409);
}
- (void)testIncompleteFileCannotBeCommittedOrPresented {
    NSData *data=[NSData dataWithBytes:"abc" length:3]; NSString *session=[self start:data]; [self.store approve:session granted:YES];
    NSError *error; XCTAssertNil([self.store finish:session error:&error]); XCTAssertEqual(error.code,409); XCTAssertNil([self.store claimForSaving:session]);
}
- (void)testWholeFileHashMismatchCleansAllStaging {
    NSData *declared=[NSData dataWithBytes:"abc" length:3], *different=[NSData dataWithBytes:"xyz" length:3];
    NSString *session=[self start:declared]; [self.store approve:session granted:YES]; [self send:different session:session];
    NSDictionary *result=[self.store finish:session error:nil]; XCTAssertEqualObjects(result[@"state"],@"failed");
    XCTAssertEqualObjects(result[@"error_code"],@"checksum_mismatch"); XCTAssertNil([self.store claimForSaving:session]);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory.path error:nil].count,0u);
}
- (void)testCancelAndLatePickerSuccessNeverBecomeSaved {
    NSData *data=NSData.data; NSString *session=[self start:data]; [self.store approve:session granted:YES]; [self.store finish:session error:nil];
    NSURL *file=[self.store claimForSaving:session]; XCTAssertNotNil(file);
    [self.store cancel:session error:nil];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:file.path],@"UIKit still owns the source until dismissal finishes");
    [self.store complete:session state:@"saved" errorCode:nil];
    NSDictionary *result=[self.store status:session error:nil]; XCTAssertEqualObjects(result[@"state"],@"cancelled"); XCTAssertFalse([result[@"saved"] boolValue]);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:file.path]);
}
- (void)testExpiryDuringSavingWaitsForUIKitAndRejectsLateSuccess {
    __block NSDate *now=[NSDate dateWithTimeIntervalSince1970:10000]; self.store.clock=^{return now;};
    NSString *session=[self start:NSData.data]; [self.store approve:session granted:YES]; [self.store finish:session error:nil];
    NSURL *file=[self.store claimForSaving:session]; now=[now dateByAddingTimeInterval:301];
    XCTAssertEqualObjects([self.store status:session error:nil][@"state"],@"expired");
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:file.path]);
    NSMutableDictionary *metadata=[[self metadata:NSData.data] mutableCopy]; metadata[@"request_id"]=@"another-request-123456";
    NSError *error; XCTAssertNil([self.store start:metadata error:&error]); XCTAssertEqual(error.code,409);
    [self.store complete:session state:@"saved" errorCode:nil];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:file.path]);
    XCTAssertFalse([[self.store status:session error:nil][@"saved"] boolValue]);
}
- (void)testIdleAndAbsoluteExpiryCannotBeKeptAliveByPolling {
    __block NSDate *now=[NSDate dateWithTimeIntervalSince1970:10000]; self.store.clock=^{return now;};
    NSString *session=[self start:NSData.data]; [self.store approve:session granted:YES];
    now=[now dateByAddingTimeInterval:301];
    XCTAssertEqualObjects([self.store status:session error:nil][@"state"],@"expired");
    XCTAssertNil([self.store claimForSaving:session]);
}
- (void)testBackgroundCancelsConfirmationAndSavingButNotAnUnrelatedTransfer {
    NSString *session=[self start:NSData.data]; [self.store cancelPendingUI]; [self.store approve:session granted:YES];
    XCTAssertEqualObjects([self.store status:session error:nil][@"state"],@"cancelled");
    NSMutableDictionary *metadata=[[self metadata:NSData.data] mutableCopy]; metadata[@"request_id"]=@"another-request-123456";
    session=[self.store start:metadata error:nil][@"session_id"]; [self.store approve:session granted:YES]; [self.store cancelPendingUI];
    XCTAssertEqualObjects([self.store status:session error:nil][@"state"],@"receiving");
}
- (void)testRestartRemovesIncompleteNativeFilesAndDoesNotPretendToResumeSaved {
    NSString *session=[self start:NSData.data]; [self.store approve:session granted:YES];
    self.store=nil; self.store=[[DSHWorkspaceExportStore alloc] initWithDirectory:self.directory];
    NSError *error; XCTAssertNil([self.store status:session error:&error]); XCTAssertEqual(error.code,404);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory.path error:nil].count,0u);
}
- (void)testTraversalSensitivePathsNamesAndInvalidSizeAreRejectedBeforeDiskWrites {
    NSArray *cases=@[@{@"source":@"/root/.ssh/id_rsa"},@{@"source":@"/root/workspace/TapGame/../secret.ipa"},
        @{@"source":@"/root/workspace/TapGame/.git/config"},@{@"source":@"/root/workspace/TapGame/id_ed25519"},
        @{@"source":@"/root/workspace/TapGame/private.pem"},@{@"source":@"/root/workspace/Other/file.ipa"},
        @{@"workspace":@"/root"},@{@"name":@"../evil.ipa"},@{@"name":@"bad\nname.ipa"},@{@"name":@".env"},
        @{@"bytes":@YES},@{@"bytes":@(-1)},@{@"bytes":@1.5},@{@"bytes":@([DSHWorkspaceExportStore maximumBytes]+1)},
        @{@"sha256":@"not-a-hash"},@{@"scope_id":@"short"}];
    for(NSDictionary *change in cases) {
        NSMutableDictionary *metadata=[[self metadata:NSData.data] mutableCopy]; [metadata addEntriesFromDictionary:change];
        NSError *error; XCTAssertNil([self.store start:metadata error:&error],@"%@",change); XCTAssertEqual(error.code,400);
    }
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory.path error:nil].count,0u);
}
@end

/*
 * Tencent is pleased to support the open source community by making wechat-matrix available.
 * Copyright (C) 2019 THL A29 Limited, a Tencent company. All rights reserved.
 * Licensed under the BSD 3-Clause License (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://opensource.org/licenses/BSD-3-Clause
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "BMFilterStackHandler.h"


// ============================================================================
#pragma mark - WCStackFeatPool
// ============================================================================

#define kStackFeat "stack_feat"
#define kStackFeatTime "stack_feat_time"

@interface WCStackFeatPool : NSObject <NSCoding,NSCopying>

@property (nonatomic, strong) NSMutableDictionary<NSNumber *,NSNumber *> *stackFeatDict;
@property (nonatomic, assign) NSTimeInterval featStackTime;

- (NSUInteger)addStackFeat:(NSUInteger)stackFeat;

@end

@implementation WCStackFeatPool

- (id)init
{
    self = [super init];
    if (self) {
        _stackFeatDict = [[NSMutableDictionary alloc] init];
        _featStackTime = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super init];
    if (self) {
        _stackFeatDict = (NSMutableDictionary *)[aDecoder decodeObjectForKey:@kStackFeat];
        _featStackTime = (NSTimeInterval)[aDecoder decodeDoubleForKey:@kStackFeatTime];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeObject:_stackFeatDict forKey:@kStackFeat];
    [aCoder encodeDouble:_featStackTime forKey:@kStackFeatTime];
}

- (NSUInteger)addStackFeat:(NSUInteger)stackFeat
{
    if (_stackFeatDict == nil) {
        return 0;
    }
    NSNumber *featNum = [NSNumber numberWithUnsignedInteger:stackFeat];
    NSNumber *featCntNum = [_stackFeatDict objectForKey:featNum];
    if (featCntNum == nil) {
        [_stackFeatDict setObject:[NSNumber numberWithUnsignedInteger:1] forKey:featNum];
        return 1;
    } else {
        NSUInteger featCnt = [featCntNum unsignedIntegerValue];
        [_stackFeatDict setObject:[NSNumber numberWithUnsignedInteger:(featCnt + 1)] forKey:featNum];
        return featCnt + 1;
    }
}

- (nonnull id)copyWithZone:(nullable NSZone *)zone {
    WCStackFeatPool *copyPool = [[WCStackFeatPool allocWithZone:zone] init];
    copyPool.stackFeatDict = [self.stackFeatDict mutableCopy];
    copyPool.featStackTime = self.featStackTime;
    return copyPool;
}

@end

// ============================================================================
#pragma mark - BMFilterStackHandler
// ============================================================================

@interface BMFilterStackHandler ()

@property (nonatomic, strong) WCStackFeatPool *stackFeatPool;

@end

@implementation BMFilterStackHandler

- (id)init
{
    self = [super init];
    if (self) {
        [self loadStackFeat];
    }
    return self;
}


static NSString *g_userDumpCachePath = nil;

+ (NSString *)diretoryOfUserDump
{
    if (g_userDumpCachePath != nil && [g_userDumpCachePath length] > 0) {
        return g_userDumpCachePath;
    }

    g_userDumpCachePath = [self crashBlockPluginCachePath];
    NSFileManager *oFileMgr = [NSFileManager defaultManager];
    if (oFileMgr != nil && [oFileMgr fileExistsAtPath:g_userDumpCachePath] == NO) {
        NSError *err;
        [oFileMgr createDirectoryAtPath:g_userDumpCachePath
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&err];
    }
    return g_userDumpCachePath;
}

static NSString* g_matrixCacheRootPath = nil;

+ (NSString *)matrixCacheRootPath
{
    if (g_matrixCacheRootPath.length > 0) {
        return g_matrixCacheRootPath;
    }
    static NSString *s_rootPath;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        s_rootPath = [paths[0] stringByAppendingString:@"/Matrix"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:s_rootPath] == NO) {
            [[NSFileManager defaultManager] createDirectoryAtPath:s_rootPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
    });
    return s_rootPath;
}


+ (void)setMatrixCacheRootPath:(NSString *)path {
    if (path.length < 1) {
        return;
    }
    g_matrixCacheRootPath = path;
}


+ (NSString *)crashBlockPluginCachePath
{
    NSString *rootPath = [[self matrixCacheRootPath] stringByAppendingPathComponent:@"CrashBlock"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:rootPath] == NO) {
        [[NSFileManager defaultManager] createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return rootPath;
}


+ (NSString *)getStackFeatFilePath
{
    NSString *ret = [self.class diretoryOfUserDump];
    ret = [ret stringByAppendingPathComponent:@"stackfeat.dat"];
    return ret;
}


- (void)loadStackFeat
{
    NSString *featPath = [self.class getStackFeatFilePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:featPath]) {
        _stackFeatPool = (WCStackFeatPool *)[NSKeyedUnarchiver unarchiveObjectWithFile:featPath];
        NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
        if ((currentTime - _stackFeatPool.featStackTime) > 86400) {
            _stackFeatPool = [[WCStackFeatPool alloc] init];
            [self saveStackFeat];
        }
    } else {
        _stackFeatPool = [[WCStackFeatPool alloc] init];
        [self saveStackFeat];
    }
}


- (void)saveStackFeat
{
    if (_stackFeatPool == nil) {
        _stackFeatPool = [[WCStackFeatPool alloc] init];
    }
    WCStackFeatPool *copyPool = [_stackFeatPool copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [NSKeyedArchiver archiveRootObject:copyPool toFile:[self.class getStackFeatFilePath]];
    });
}

- (NSUInteger)addStackFeat:(NSUInteger)stackFeat
{
    if (_stackFeatPool == nil) {
        return 1;
    }
    NSUInteger repeat = [_stackFeatPool addStackFeat:stackFeat];
    [self saveStackFeat];
    return repeat;
}

@end

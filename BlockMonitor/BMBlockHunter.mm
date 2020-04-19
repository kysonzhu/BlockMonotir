//
//  BMBlockHunter.m
//  BMHunterKit
//
//  Created by kyson on 2019/8/20.
//
#import <UIKit/UIKit.h>
#import <vector>

#import <execinfo.h>
#import <sys/time.h>
#import "BMBlockHunter.h"
#import "BMFilterStackHandler.h"
#import "BMGetMainThreadUtil.h"
#import "BMMainThreadHandler.h"
#import "BMSymbolicator.h"

static BOOL g_bRun;
static struct timeval g_tvRun;

#define BM_MicroFormat_MillSecond 1000
#define BM_MicroFormat_Second 1000000

#define WXGBackTraceMaxEntries 300

const static useconds_t g_defaultRunLoopTimeOut = 2 * BM_MicroFormat_Second;
const static useconds_t g_defaultCheckPeriodTime = 1 * BM_MicroFormat_Second;
const static useconds_t g_defaultPerStackInterval = 50 * BM_MicroFormat_MillSecond;

static uint32_t g_triggerdFilterSameCnt = 0;

static size_t g_StackMaxCount = 100;
static NSUInteger g_CurrentThreadCount = 0;

static useconds_t g_PerStackInterval = g_defaultPerStackInterval;

static useconds_t g_RunLoopTimeOut = g_defaultRunLoopTimeOut;
static useconds_t g_CheckPeriodTime = g_defaultCheckPeriodTime;

static BMStackCursor *g_PointMainThreadArray = NULL;

const static int g_defaultMainThreadCount = 10;

@interface BMBlockHunter () {
    CFRunLoopObserverRef m_runLoopObserver;
    BMMainThreadHandler *m_pointMainThreadHandler;

    std::vector<NSUInteger> m_vecLastMainThreadCallStack;
    NSUInteger m_lastMainThreadStackCount;
    BMFilterStackHandler *m_stackHandler;

    NSThread *m_monitorThread;
    NSUInteger m_nLastTimeInterval;

    uint64_t m_blockDiffTime;
    NSUInteger m_nIntervalTime;
    BOOL m_bStop;
}

@property (nonatomic, strong) NSDictionary *result;
@property (atomic, assign) BOOL stopObserver;
@property (atomic, assign) NSInteger timeCount;

@property (nonatomic, strong) NSMutableArray *backtrace;

@end

@implementation BMBlockHunter

- (instancetype)init
{
    self = [super init];
    if (self) {
        m_bStop = NO;
        m_nIntervalTime = 1;
        m_nLastTimeInterval = 1;
        
        m_pointMainThreadHandler = [[BMMainThreadHandler alloc] initWithCycleArrayCount:g_defaultMainThreadCount];
        g_triggerdFilterSameCnt = 10;
        
        [self addRunLoopObserver];
        [self addMonitorThread];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onAppTerminate)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
    }
    return self;
}

- (void)addMonitorThread {
    m_bStop = NO;
    m_monitorThread = [[NSThread alloc] initWithTarget:self selector:@selector(threadProc) object:nil];
    [m_monitorThread start];
}

- (void)onAppTerminate {
    self.stopObserver = YES;
    [self stop];
}

+ (unsigned long long)diffTime:(struct timeval *)tvStart endTime:(struct timeval *)tvEnd {
    return 1000000 * (tvEnd->tv_sec - tvStart->tv_sec) + tvEnd->tv_usec - tvStart->tv_usec;
}

- (EDumpType)check {
    BOOL tmp_g_bRun = g_bRun;
    struct timeval tmp_g_tvRun = g_tvRun;
    struct timeval tvCur;
    gettimeofday(&tvCur, NULL);

    unsigned long long diff = [self.class diffTime:&tmp_g_tvRun endTime:&tvCur];

    m_blockDiffTime = 0;
    if (tmp_g_bRun && tmp_g_tvRun.tv_sec && tmp_g_tvRun.tv_usec && __timercmp(&tmp_g_tvRun, &tvCur, <) &&
        diff > g_RunLoopTimeOut) {
        m_blockDiffTime = diff;
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            return EDumpType_BackgroundMainThreadBlock;
        }
        return EDumpType_MainThreadBlock;
    }
    return EDumpType_Unlag;
}

- (NSString *)hnt_observePropertyName {
    return @"result";
}

- (void)addRunLoopObserver {
    // 注册RunLoop状态观察
    CFRunLoopObserverContext context = {0, (__bridge void *)self, NULL, NULL};
    m_runLoopObserver = CFRunLoopObserverCreate(
        kCFAllocatorDefault, kCFRunLoopAllActivities, YES, LONG_MIN, &myRunLoopBeginCallback, &context);

    NSRunLoop *curRunLoop = [NSRunLoop currentRunLoop];
    CFRunLoopRef runloop = [curRunLoop getCFRunLoop];
    CFRunLoopAddObserver(runloop, m_runLoopObserver, kCFRunLoopCommonModes);
}

- (EFilterType)needFilter {
    BOOL bIsSame = NO;
    static std::vector<NSUInteger> vecCallStack(300);
    __block NSUInteger nSum = 0;
    __block NSUInteger stackFeat = 0; // use the top stack address;

    nSum = [m_pointMainThreadHandler getLastMainThreadStackCount];
    uintptr_t *stack = [m_pointMainThreadHandler getLastMainThreadStack];
    if (stack) {
        for (size_t i = 0; i < nSum; i++) {
            vecCallStack[i] = stack[i];
        }
        stackFeat = kssymbolicate_symboladdress(stack[0]);
    } else {
        nSum = 0;
    }

    if (nSum <= 1) {
        return EFilterType_Meaningless;
    }

    if (nSum == m_lastMainThreadStackCount) {
        NSUInteger index = 0;
        for (index = 0; index < nSum; index++) {
            if (vecCallStack[index] != m_vecLastMainThreadCallStack[index]) {
                break;
            }
        }
        if (index == nSum) {
            bIsSame = YES;
        }
    }

    if (bIsSame) {
        //退火算法，使用斐波那契数列
        NSUInteger lastTimeInterval = m_nIntervalTime;
        m_nIntervalTime = m_nLastTimeInterval + m_nIntervalTime;
        m_nLastTimeInterval = lastTimeInterval;
        return EFilterType_Annealing;
    } else {
        m_nIntervalTime = 1;
        m_nLastTimeInterval = 1;

        // update last call stack
        m_vecLastMainThreadCallStack.clear();
        m_lastMainThreadStackCount = 0;
        for (NSUInteger index = 0; index < nSum; index++) {
            m_vecLastMainThreadCallStack.push_back(vecCallStack[index]);
            m_lastMainThreadStackCount++;
        }
        //过滤重复的 stack
        NSUInteger repeatCnt = [m_stackHandler addStackFeat:stackFeat];
        if (repeatCnt > g_triggerdFilterSameCnt) {
            return EFilterType_TrigerByTooMuch;
        }
        return EFilterType_None;
    }
}

// 开始监听
- (void)threadProc {
    m_stackHandler = [[BMFilterStackHandler alloc] init];

    while (YES) {
        @autoreleasepool {
            EDumpType dumpType = [self check];
            if (m_bStop) {
                break;
            }

            if (dumpType != EDumpType_Unlag) {
                EFilterType filterType = [self needFilter];
                if (filterType == EFilterType_None) {
                    if (g_PointMainThreadArray != NULL) {
                        free(g_PointMainThreadArray);
                        g_PointMainThreadArray = NULL;
                    }
                    g_PointMainThreadArray = [m_pointMainThreadHandler getPointStackCursor];
                    if (g_PointMainThreadArray != NULL) {
                        BMStackCursor_Backtrace_Context *context =
                            (BMStackCursor_Backtrace_Context *)g_PointMainThreadArray->context;
                        if (context->backtrace) {
                            free((uintptr_t *)context->backtrace);
                        }
                        free(g_PointMainThreadArray);
                        g_PointMainThreadArray = NULL;
                    }
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSDictionary *hunter = @{@"block_status":@(self->m_blockDiffTime / 1000)};
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"block_notification" object:hunter];
                    });
                }

            } else {
                [self resetStatus];
            }

            for (int nCnt = 0; nCnt < m_nIntervalTime && !m_bStop; nCnt++) {
                int intervalCount = g_CheckPeriodTime / g_PerStackInterval;
                if (intervalCount <= 0) {
                    usleep(g_CheckPeriodTime);
                } else {
                    for (int index = 0; index < intervalCount && !m_bStop; index++) {
                        usleep(g_PerStackInterval);
                        size_t stackBytes = sizeof(uintptr_t) * g_StackMaxCount;
                        uintptr_t *stackArray = (uintptr_t *)malloc(stackBytes);
                        if (stackArray == NULL) {
                            continue;
                        }
                        __block size_t nSum = 0;
                        memset(stackArray, 0, stackBytes);
                        [BMGetMainThreadUtil
                            getCurrentMainThreadStack:^(NSUInteger pc) {
                                stackArray[nSum] = (uintptr_t)pc;
                                nSum++;
                            }
                                       withMaxEntries:g_StackMaxCount
                                      withThreadCount:g_CurrentThreadCount];
                        [m_pointMainThreadHandler addThreadStack:stackArray andStackCount:nSum];
                    }
                }
            }
        }

        if (m_bStop) {
            break;
        }
    }
}

#pragma mark - runloop observer callback
// 就是runloop有一个状态改变 就记录一下
static void myRunLoopBeginCallback(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    switch (activity) {
        case kCFRunLoopEntry: {
            g_bRun = YES;
        } break;
        case kCFRunLoopBeforeTimers: {
            if (g_bRun == NO) {
                gettimeofday(&g_tvRun, NULL);
            }
            g_bRun = YES;
        } break;
        case kCFRunLoopBeforeWaiting: {
            gettimeofday(&g_tvRun, NULL);
            g_bRun = NO;
        }
        break;

        case kCFRunLoopBeforeSources: {
            if (g_bRun == NO) {
                gettimeofday(&g_tvRun, NULL);
            }
            g_bRun = YES;
        } break;

        case kCFRunLoopAfterWaiting: {
            if (g_bRun == NO) {
                gettimeofday(&g_tvRun, NULL);
            }
            g_bRun = YES;
        } break;

        case kCFRunLoopAllActivities:
            break;
        case kCFRunLoopExit: {
            g_bRun = NO;
        } break;
        default:
            break;
    }
}

- (void)resetStatus {
    m_nIntervalTime = 1;
    m_nLastTimeInterval = 1;
    m_blockDiffTime = 0;
    m_vecLastMainThreadCallStack.clear();
    m_lastMainThreadStackCount = 0;
}

- (void)stop {
    if (m_bStop) {
        return;
    }

    m_bStop = YES;

    [self removeRunLoopObserver];

    while ([m_monitorThread isExecuting]) {
        usleep(100 * BM_MicroFormat_MillSecond);
    }
}

- (void)removeRunLoopObserver {
    NSRunLoop *curRunLoop = [NSRunLoop currentRunLoop];
    CFRunLoopRef runloop = [curRunLoop getCFRunLoop];
    CFRunLoopRemoveObserver(runloop, m_runLoopObserver, kCFRunLoopCommonModes);
}

// 停止监听
- (void)dealloc {
    [self stop];
}

@end

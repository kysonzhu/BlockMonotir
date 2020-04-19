//
//  BMBlockHunter.h
//  BMHunterKit
//
//  Created by kyson on 2019/8/20.
//

#import <Foundation/Foundation.h>



NS_ASSUME_NONNULL_BEGIN


typedef NS_ENUM(NSUInteger, EFilterType) {
    EFilterType_None = 0,
    EFilterType_Meaningless = 1, // the adress count of the stack is too little
    EFilterType_Annealing = 2, // the Annealing algorithm, filter the continuous same stack
    EFilterType_TrigerByTooMuch = 3, // filter the stack that appear too much one day
};

// Define the type of the lag
typedef NS_ENUM(NSUInteger, EDumpType) {
    EDumpType_Unlag = 2000,
    EDumpType_MainThreadBlock = 2001, // foreground main thread block
    EDumpType_BackgroundMainThreadBlock = 2002, // background main thread block
    EDumpType_CPUBlock = 2003, // CPU too high
    EDumpType_BlockThreadTooMuch = 2009, // main thread block and the thread is too much. (more than 64 threads)
    EDumpType_BlockAndBeKilled = 2010, // main thread block and killed by the system
    EDumpType_PowerConsume = 2011, // battery cost stack report
    EDumpType_Test = 10000,
};

#define __timercmp(tvp, uvp, cmp) \
    (((tvp)->tv_sec == (uvp)->tv_sec) ? ((tvp)->tv_usec cmp(uvp)->tv_usec) : ((tvp)->tv_sec cmp(uvp)->tv_sec))



@interface BMBlockHunter : NSObject



@end

NS_ASSUME_NONNULL_END

//
//  BMStackCursor.h
//
//  Copyright (c) 2016 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
#ifndef BMStackCursor_h
#define BMStackCursor_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <sys/types.h>
#include <mach/mach_types.h>
#include <stdbool.h>
#include <sys/ucontext.h>

#define KSSC_CONTEXT_SIZE 100

/** Point at which to give up walking a stack and consider it a stack overflow. */
#define KSSC_STACK_OVERFLOW_THRESHOLD 150

#define KSPACStrippingMask_ARM64e 0x0000000fffffffff

#ifdef __arm64__
    #define STRUCT_MCONTEXT_L _STRUCT_MCONTEXT64
#else
    #define STRUCT_MCONTEXT_L _STRUCT_MCONTEXT
#endif

typedef struct KSMachineContext
{
    thread_t thisThread;
    thread_t allThreads[100];
    int threadCount;
    bool isCrashedContext;
    bool isCurrentThread;
    bool isStackOverflow;
    bool isSignalContext;
    STRUCT_MCONTEXT_L machineContext;
} KSMachineContext;

typedef struct BMStackCursor
{
    struct
    {
        /** Current address in the stack trace. */
        uintptr_t address;
        
        /** The name (if any) of the binary image the current address falls inside. */
        const char* imageName;
        
        /** The starting address of the binary image the current address falls inside. */
        uintptr_t imageAddress;
        
        /** The name (if any) of the closest symbol to the current address. */
        const char* symbolName;
        
        /** The address of the closest symbol to the current address. */
        uintptr_t symbolAddress;
    } stackEntry;
    struct
    {
        /** Current depth as we walk the stack (1-based). */
        int currentDepth;
        
        /** If true, cursor has given up walking the stack. */
        bool hasGivenUp;
    } state;

    /** Reset the cursor back to the beginning. */
    void (*resetCursor)(struct BMStackCursor*);

    /** Advance the cursor to the next stack entry. */
    bool (*advanceCursor)(struct BMStackCursor*);
    
    /** Attempt to symbolicate the current address, filling in the fields in stackEntry. */
    bool (*symbolicate)(struct BMStackCursor*);
    
    /** Internal context-specific information. */
    void* context[KSSC_CONTEXT_SIZE];
} BMStackCursor;

typedef struct FrameEntry
{
    /** The previous frame in the list. */
    struct FrameEntry* previous;
    
    /** The instruction address. */
    uintptr_t return_address;
} FrameEntry;


typedef struct
{
    const struct KSMachineContext* machineContext;
    int maxStackDepth;
    FrameEntry currentFrame;
    uintptr_t instructionAddress;
    uintptr_t linkRegister;
    bool isPastFramePointer;
} MachineContextCursor;

/** Common initialization routine for a stack cursor.
 *  Note: This is intended primarily for other cursors to call.
 *
 * @param cursor The cursor to initialize.
 *
 * @param resetCursor Function that will reset the cursor (NULL = default: Do nothing).
 *
 * @param advanceCursor Function to advance the cursor (NULL = default: Do nothing and return false).
 */
void kssc_initCursor(BMStackCursor *cursor,
                     void (*resetCursor)(BMStackCursor*),
                     bool (*advanceCursor)(BMStackCursor*));

/** Reset a cursor.
 *  INTERNAL METHOD. Do not call!
 *
 * @param cursor The cursor to reset.
 */
void kssc_resetCursor(BMStackCursor *cursor);

/** Initialize a stack cursor for a machine context.
 *
 * @param cursor The stack cursor to initialize.
 *
 * @param maxStackDepth The max depth to search before giving up.
 *
 * @param machineContext The machine context whose stack to walk.
 */
void kssc_initWithMachineContext(BMStackCursor *cursor, int maxStackDepth, const struct KSMachineContext* machineContext);
    
typedef uintptr_t BMThread;

int kssc_backtraceCurrentThread(BMThread currentThread, uintptr_t* backtraceBuffer, int maxEntries);

#ifdef __cplusplus
}
#endif

#endif // BMStackCursor_h

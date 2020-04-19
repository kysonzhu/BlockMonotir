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


#include "BMStackCursor.h"
#include "BMSymbolicator.h"
#include <stdlib.h>
#include <mach/mach.h>
#include <mach/mach_types.h>
#include <stdbool.h>
#include <sys/ucontext.h>
#include <execinfo.h>


#define KSMC_NEW_CONTEXT(NAME) \
char ksmc_##NAME##_storage[ksmc_contextSize()]; \
struct KSMachineContext* NAME = (struct KSMachineContext*)ksmc_##NAME##_storage


static bool g_advanceCursor(__unused BMStackCursor *cursor)
{
    return false;
}

void kssc_resetCursor(BMStackCursor *cursor)
{
    cursor->state.currentDepth = 0;
    cursor->state.hasGivenUp = false;
    cursor->stackEntry.address = 0;
    cursor->stackEntry.imageAddress = 0;
    cursor->stackEntry.imageName = NULL;
    cursor->stackEntry.symbolAddress = 0;
    cursor->stackEntry.symbolName = NULL;
}

void kssc_initCursor(BMStackCursor *cursor,
                     void (*resetCursor)(BMStackCursor*),
                     bool (*advanceCursor)(BMStackCursor*))
{
    cursor->symbolicate = kssymbolicator_symbolicate;
    cursor->advanceCursor = advanceCursor != NULL ? advanceCursor : g_advanceCursor;
    cursor->resetCursor = resetCursor != NULL ? resetCursor : kssc_resetCursor;
    cursor->resetCursor(cursor);
}





/** Represents an entry in a frame list.
 * This is modeled after the various i386/x64 frame walkers in the xnu source,
 * and seems to work fine in ARM as well. I haven't included the args pointer
 * since it's not needed in this context.
 */

/*
 
 comment by @SecondDog
 
 try to explain why it is work in arm64:
 
 as we know ,arm stack layout is like this:
 so the pre FP should be *(current FP - 32)
 
 -------------  <---------- current FP
 | PC         |
 -------------  <---------- current FP - 8
 | LR         |
 -------------  <---------- current FP - 16
 | SP         |
 -------------  <---------- current FP - 24
 | FP(pre)    |
 -------------  <---------- current FP - 32
 
 the struct FrameEntry is defined like this
 typedef struct FrameEntry
 {
 struct FrameEntry* previous; <----- this pointer is 8 byte in arm64
 uintptr_t return_address;  <------ this value is also 8 byte
 } FrameEntry; <----- 16byte total
 
 
 but the arm64 call stack is like this.
 -------------
 | LR(x30)     |
 -------------
 | pre FP(x29) |
 -------------  <-----Current FP
 
 so copy 16 byte data to the FrameEntry is just fit in arm64,so it works fine in arm64
 
 */




#if defined (__arm64__)

uintptr_t kscpu_framePointer(const KSMachineContext* const context)
{
    return context->machineContext.__ss.__fp;
}

uintptr_t kscpu_instructionAddress(const KSMachineContext* const context)
{
    return context->machineContext.__ss.__pc;
}

#endif

#if defined (__x86_64__)

uintptr_t kscpu_framePointer(const KSMachineContext* const context)
{
    return context->machineContext.__ss.__rbp;
}

uintptr_t kscpu_instructionAddress(const KSMachineContext* const context)
{
    return context->machineContext.__ss.__rip;
}

#endif

static inline int copySafely(const void* restrict const src, void* restrict const dst, const int byteCount)
{
    vm_size_t bytesCopied = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(),
                                             (vm_address_t)src,
                                             (vm_size_t)byteCount,
                                             (vm_address_t)dst,
                                             &bytesCopied);
    if(result != KERN_SUCCESS)
    {
        return 0;
    }
    return (int)bytesCopied;
}

bool ksmem_copySafely(const void* restrict const src, void* restrict const dst, const int byteCount)
{
    return copySafely(src, dst, byteCount);
}


uintptr_t kscpu_normaliseInstructionPointer(uintptr_t ip)
{
    return ip & KSPACStrippingMask_ARM64e;
}

static bool advanceCursor(BMStackCursor *cursor)
{
    MachineContextCursor* context = (MachineContextCursor*)cursor->context;
    uintptr_t nextAddress = 0;
    
    if(cursor->state.currentDepth >= KSSC_STACK_OVERFLOW_THRESHOLD)
    {
        cursor->state.hasGivenUp = true;
    }
    
    if(cursor->state.currentDepth >= context->maxStackDepth)
    {
        cursor->state.hasGivenUp = true;
        return false;
    }
    
    if(context->instructionAddress == 0)
    {
        context->instructionAddress = kscpu_instructionAddress(context->machineContext);
        if(context->instructionAddress == 0)
        {
            return false;
        }
        nextAddress = context->instructionAddress;
        goto successfulExit;
    }

    if(context->currentFrame.previous == NULL)
    {
        if(context->isPastFramePointer)
        {
            return false;
        }
        context->currentFrame.previous = (struct FrameEntry*)kscpu_framePointer(context->machineContext);
        context->isPastFramePointer = true;
    }

    if(!ksmem_copySafely(context->currentFrame.previous, &context->currentFrame, sizeof(context->currentFrame)))
    {
        return false;
    }
    if(context->currentFrame.previous == 0 || context->currentFrame.return_address == 0)
    {
        return false;
    }

    nextAddress = context->currentFrame.return_address;
    
successfulExit:
    cursor->stackEntry.address = kscpu_normaliseInstructionPointer(nextAddress);
    cursor->state.currentDepth++;
    return true;
}

static void resetCursor(BMStackCursor* cursor)
{
    kssc_resetCursor(cursor);
    MachineContextCursor* context = (MachineContextCursor*)cursor->context;
    context->currentFrame.previous = 0;
    context->currentFrame.return_address = 0;
    context->instructionAddress = 0;
    context->linkRegister = 0;
    context->isPastFramePointer = 0;
}

void kssc_initWithMachineContext(BMStackCursor *cursor, int maxStackDepth, const struct KSMachineContext* machineContext)
{
    //初始化 cursor
    kssc_initCursor(cursor, resetCursor, advanceCursor);
    MachineContextCursor* context = (MachineContextCursor*)cursor->context;
    context->machineContext = machineContext;
    context->maxStackDepth = maxStackDepth;
    context->instructionAddress = cursor->stackEntry.address;
}






int ksmc_contextSize()
{
    return sizeof(KSMachineContext);
}



static inline bool isSignalContext(const KSMachineContext* const context)
{
    return context->isSignalContext;
}


static inline bool isContextForCurrentThread(const KSMachineContext* const context)
{
    return context->isCurrentThread;
}

bool ksmc_canHaveCPUState(const KSMachineContext* const context)
{
    return !isContextForCurrentThread(context) || isSignalContext(context);
}


bool kscpu_i_fillState(const thread_t thread,
                       const thread_state_t state,
                       const thread_state_flavor_t flavor,
                       const mach_msg_type_number_t stateCount)
{
    mach_msg_type_number_t stateCountBuff = stateCount;
    kern_return_t kr;
    
    kr = thread_get_state(thread, flavor, state, &stateCountBuff);
    if(kr != KERN_SUCCESS)
    {
        return false;
    }
    return true;
}

#if defined (__arm64__)

void kscpu_getState(KSMachineContext* context)
{
    thread_t thread = context->thisThread;
    STRUCT_MCONTEXT_L* const machineContext = &context->machineContext;
    
    kscpu_i_fillState(thread, (thread_state_t)&machineContext->__ss, ARM_THREAD_STATE64, ARM_THREAD_STATE64_COUNT);
    kscpu_i_fillState(thread, (thread_state_t)&machineContext->__es, ARM_EXCEPTION_STATE64, ARM_EXCEPTION_STATE64_COUNT);
}

#endif

#if defined (__x86_64__)

void kscpu_getState(KSMachineContext* context)
{
    thread_t thread = context->thisThread;
    STRUCT_MCONTEXT_L* const machineContext = &context->machineContext;
    
    kscpu_i_fillState(thread, (thread_state_t)&machineContext->__ss, x86_THREAD_STATE64, x86_THREAD_STATE64_COUNT);
    kscpu_i_fillState(thread, (thread_state_t)&machineContext->__es, x86_EXCEPTION_STATE64, x86_EXCEPTION_STATE64_COUNT);
}

#endif


bool ksmc_isCrashedContext(const KSMachineContext* const context)
{
    return context->isCrashedContext;
}


static inline bool isStackOverflow(const KSMachineContext* const context)
{
    BMStackCursor stackCursor;
    kssc_initWithMachineContext(&stackCursor, KSSC_STACK_OVERFLOW_THRESHOLD, context);
    while(stackCursor.advanceCursor(&stackCursor))
    {
    }
    return stackCursor.state.hasGivenUp;
}

static inline bool getThreadList(KSMachineContext* context)
{
    const task_t thisTask = mach_task_self();
    kern_return_t kr;
    thread_act_array_t threads;
    mach_msg_type_number_t actualThreadCount;

    if((kr = task_threads(thisTask, &threads, &actualThreadCount)) != KERN_SUCCESS)
    {
        return false;
    }

    int threadCount = (int)actualThreadCount;
    int maxThreadCount = sizeof(context->allThreads) / sizeof(context->allThreads[0]);
    if(threadCount > maxThreadCount)
    {
        threadCount = maxThreadCount;
    }
    for(int i = 0; i < threadCount; i++)
    {
        context->allThreads[i] = threads[i];
    }
    context->threadCount = threadCount;

    for(mach_msg_type_number_t i = 0; i < actualThreadCount; i++)
    {
        mach_port_deallocate(thisTask, context->allThreads[i]);
    }
    vm_deallocate(thisTask, (vm_address_t)threads, sizeof(thread_t) * actualThreadCount);

    return true;
}

BMThread ksthread_self()
{
    thread_t thread_self = mach_thread_self();
    mach_port_deallocate(mach_task_self(), thread_self);
    return (BMThread)thread_self;
}

bool ksmc_getContextForThread(BMThread thread, KSMachineContext* destinationContext, bool isCrashedContext)
{
    memset(destinationContext, 0, sizeof(*destinationContext));
    destinationContext->thisThread = (thread_t)thread;
    destinationContext->isCurrentThread = thread == ksthread_self();
    destinationContext->isCrashedContext = isCrashedContext;
    destinationContext->isSignalContext = false;
    if(ksmc_canHaveCPUState(destinationContext))
    {
        kscpu_getState(destinationContext);
    }
    if(ksmc_isCrashedContext(destinationContext))
    {
        destinationContext->isStackOverflow = isStackOverflow(destinationContext);
        getThreadList(destinationContext);
    }
    return true;
}



int kssc_backtraceCurrentThread(BMThread currentThread, uintptr_t* backtraceBuffer, int maxEntries)
{
    if (maxEntries == 0)
    {
        return 0;
    }
    
    KSMC_NEW_CONTEXT(machineContext);
    ksmc_getContextForThread(currentThread, machineContext, false);
    BMStackCursor stackCursor;
    kssc_initWithMachineContext(&stackCursor, maxEntries, machineContext);
    
    int i = 0;
    while (stackCursor.advanceCursor(&stackCursor)) {
        backtraceBuffer[i] = stackCursor.stackEntry.address;
        i++;
    }
    return i;
}

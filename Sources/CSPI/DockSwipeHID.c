// DockSwipe via IOHIDEvent payload (macOS 27+). See CoreGraphicsSPI.h for provenance.
// This is the code path proven by the A/B Space-switch test on macOS 27.0.1:
// the legacy CGEvent-field swipe did nothing, this payload switched Spaces.

#include "CoreGraphicsSPI.h"
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

extern IOHIDEventRef IOHIDEventCreate(CFAllocatorRef allocator, uint32_t type,
                                      uint64_t timeStamp, uint32_t options);
extern void    IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, CFIndex value);
extern CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef event, uint32_t field);
extern void    IOHIDEventSetDoubleValue(IOHIDEventRef event, uint32_t field, double value);
extern double  IOHIDEventGetDoubleValue(IOHIDEventRef event, uint32_t field);
extern void    IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern uint16_t   IOHIDEventGetPhase(IOHIDEventRef event);
extern uint32_t   IOHIDEventGetType(IOHIDEventRef event);
extern CFArrayRef IOHIDEventGetChildren(IOHIDEventRef event);

typedef void (*KMCSLEventSetIOHIDEventFn)(CGEventRef, IOHIDEventRef);
typedef IOHIDEventRef (*KMCSLEventCopyIOHIDEventFn)(CGEventRef);

static KMCSLEventSetIOHIDEventFn  sSetHIDEvent;
static KMCSLEventCopyIOHIDEventFn sCopyHIDEvent;
static pthread_once_t sLoadOnce = PTHREAD_ONCE_INIT;

static void loadSkyLight(void) {
    // Resolved at runtime: SkyLight is private, and failing to resolve must not
    // prevent the app from launching (it only disables Space switching).
    void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!handle) return;
    sSetHIDEvent  = (KMCSLEventSetIOHIDEventFn)dlsym(handle, "SLEventSetIOHIDEvent");
    sCopyHIDEvent = (KMCSLEventCopyIOHIDEventFn)dlsym(handle, "SLEventCopyIOHIDEvent");
}

bool KMCDockSwipeHIDPathAvailable(void) {
    pthread_once(&sLoadOnce, loadSkyLight);
    return sSetHIDEvent != NULL;
}

CGEventRef KMCCreateDockSwipeHIDEvent(uint32_t motion, uint16_t phase, double progress, double velocity) {
    if (!KMCDockSwipeHIDPathAvailable()) return NULL;

    IOHIDEventRef hid = IOHIDEventCreate(kCFAllocatorDefault, KMCHIDEventTypeDockSwipe, 0,
                                         ((uint32_t)phase) << KMCHIDEventPhaseShift);
    if (!hid) return NULL;

    IOHIDEventSetIntegerValue(hid, KMCHIDFieldDockSwipeMotion, motion);
    IOHIDEventSetIntegerValue(hid, KMCHIDFieldDockSwipeFlavor, KMCHIDGestureFlavorDockPrimary);
    IOHIDEventSetDoubleValue(hid, KMCHIDFieldDockSwipeProgress, progress);

    if (phase == KMCHIDEventPhaseEnded || phase == KMCHIDEventPhaseCancelled) {
        IOHIDEventRef child = IOHIDEventCreate(kCFAllocatorDefault, KMCHIDEventTypeVelocity, 0, 0);
        if (child) {
            IOHIDEventSetDoubleValue(child, KMCHIDFieldVelocityX, velocity);
            IOHIDEventSetDoubleValue(child, KMCHIDFieldVelocityY, velocity);
            IOHIDEventSetDoubleValue(child, KMCHIDFieldVelocityZ, 0.0);
            IOHIDEventAppendEvent(hid, child, 0);   // parent retains the child
            CFRelease(child);
        }
    }

    CGEventRef event = CGEventCreate(NULL);
    if (!event) {
        CFRelease(hid);
        return NULL;
    }
    CGEventSetType(event, (CGEventType)30);
    sSetHIDEvent(event, hid);   // copies the payload and takes no retain on `hid` (MMF PR #1936)
    CFRelease(hid);
    return event;
}

bool KMCInspectDockSwipeHIDEvent(CGEventRef event, KMCDockSwipeInfo *outInfo) {
    if (!event || !outInfo || !KMCDockSwipeHIDPathAvailable() || !sCopyHIDEvent) return false;
    IOHIDEventRef copy = sCopyHIDEvent(event);
    if (!copy) return false;

    memset(outInfo, 0, sizeof *outInfo);
    outInfo->type     = IOHIDEventGetType(copy);
    outInfo->phase    = IOHIDEventGetPhase(copy);
    outInfo->motion   = IOHIDEventGetIntegerValue(copy, KMCHIDFieldDockSwipeMotion);
    outInfo->flavor   = IOHIDEventGetIntegerValue(copy, KMCHIDFieldDockSwipeFlavor);
    outInfo->progress = IOHIDEventGetDoubleValue(copy, KMCHIDFieldDockSwipeProgress);

    CFArrayRef children = IOHIDEventGetChildren(copy);
    outInfo->childCount = children ? CFArrayGetCount(children) : 0;
    if (outInfo->childCount > 0) {
        IOHIDEventRef child = (IOHIDEventRef)CFArrayGetValueAtIndex(children, 0);
        outInfo->childType = IOHIDEventGetType(child);
        outInfo->velocityX = IOHIDEventGetDoubleValue(child, KMCHIDFieldVelocityX);
        outInfo->velocityY = IOHIDEventGetDoubleValue(child, KMCHIDFieldVelocityY);
    }
    CFRelease(copy);
    return true;
}

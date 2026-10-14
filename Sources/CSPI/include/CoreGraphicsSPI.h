// Private SPI declarations for CGEvent <-> IOHIDEvent interop
// Required for full scroll reversal (including IOHID-level delta values)

#ifndef CoreGraphicsSPI_h
#define CoreGraphicsSPI_h

#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hidsystem/IOHIDLib.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

// Extract underlying IOHIDEvent from a CGEvent (retained, must CFRelease)
extern IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef event);

// IOHIDEvent scroll field constants
// Field type 6 = kIOHIDEventTypeScroll
enum {
    kIOHIDEventFieldScrollX = (6 << 16) | 0,
    kIOHIDEventFieldScrollY = (6 << 16) | 1,
};

extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);

// Safe release for IOHIDEventRef (which is a CF type returned by CGEventCopyIOHIDEvent)
static inline void IOHIDEventSafeRelease(IOHIDEventRef event) {
    CFRelease(event);
}

// MARK: - DockSwipe via IOHIDEvent payload (macOS 27+)
//
// macOS 27 no longer reads the legacy CGEvent fields (124/132/135/136...) of a
// synthetic dock swipe. It reads an IOHIDEvent attached to a type-30 CGEvent instead.
// Discovery: Mac Mouse Fix commit f92d2d53a (Noah Nuebling). Setter + ownership
// semantics: MMF PR #1936 (SLEventSetIOHIDEvent copies the payload, takes no retain).
//
// Raw values verified against IOHIDEventTypes.h / IOHIDEventFieldDefs.h (enum
// positions counted) and by a runtime round-trip on macOS 27.0.1 (26A434).
// Field ids also match MMF's runtime field enumeration (1507329/1507330/1507333).

#include <stdbool.h>

enum {
    KMCHIDEventTypeVelocity        = 9,
    KMCHIDEventTypeDockSwipe       = 23,

    KMCHIDFieldVelocityX           = (9 << 16) | 0,    // 589824
    KMCHIDFieldVelocityY           = (9 << 16) | 1,    // 589825
    KMCHIDFieldVelocityZ           = (9 << 16) | 2,    // 589826
    KMCHIDFieldDockSwipeMotion     = (23 << 16) | 1,   // 1507329
    KMCHIDFieldDockSwipeProgress   = (23 << 16) | 2,   // 1507330
    KMCHIDFieldDockSwipeFlavor     = (23 << 16) | 5,   // 1507333

    KMCHIDGestureMotionHorizontalX = 1,
    KMCHIDGestureFlavorDockPrimary = 3,

    KMCHIDEventPhaseBegan          = 1 << 0,
    KMCHIDEventPhaseChanged        = 1 << 1,
    KMCHIDEventPhaseEnded          = 1 << 2,
    KMCHIDEventPhaseCancelled      = 1 << 3,
    KMCHIDEventPhaseShift          = 24,               // kIOHIDEventEventOptionPhaseShift
};

/// True when SkyLight's SLEventSetIOHIDEvent resolved. When false, callers must fail
/// closed — the legacy field path is known to do nothing on macOS 27.
bool KMCDockSwipeHIDPathAvailable(void);

/// Creates a type-30 CGEvent carrying a DockSwipe IOHIDEvent payload. Caller owns it.
/// `velocity` is attached as a Velocity child event only for ended/cancelled phases.
/// Returns NULL if the SkyLight setter is unavailable or allocation fails.
CGEventRef _Nullable KMCCreateDockSwipeHIDEvent(uint32_t motion, uint16_t phase,
                                                 double progress, double velocity) CF_RETURNS_RETAINED;

/// DockSwipe payload as read back out of a CGEvent (tests / diagnostics only).
typedef struct {
    uint32_t type;
    uint16_t phase;
    long     motion;
    long     flavor;
    double   progress;
    long     childCount;
    uint32_t childType;
    double   velocityX;
    double   velocityY;
} KMCDockSwipeInfo;

/// Reads the attached DockSwipe payload. Returns false if there is none.
bool KMCInspectDockSwipeHIDEvent(CGEventRef _Nonnull event, KMCDockSwipeInfo * _Nonnull outInfo);

#endif /* CoreGraphicsSPI_h */

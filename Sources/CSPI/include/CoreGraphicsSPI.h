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

#endif /* CoreGraphicsSPI_h */

#include <AppKit/AppKit.h>
#include <QWidget>
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

extern "C" void showLookupForString(WId winId, const char* text, double x, double y) {
    if (winId == 0 || text == nullptr) return;

    NSView* view = (NSView*)winId;
    NSString* nsText = [NSString stringWithUTF8String:text];

    NSPoint point = NSMakePoint(x, y);

    [view showDefinitionForAttributedString:[[NSAttributedString alloc] initWithString:nsText]
                                    atPoint:point];
}

extern "C" void changeTitlebarColor(WId winId, double red, double green, double blue, double alpha){
    if (winId == 0) return;
    NSView* view = (NSView*)winId;
    NSWindow* window = [view window];
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = [NSColor colorWithRed:red green:green blue:blue alpha: alpha];
}

@interface SioyekTitlebarController : NSObject {
    NSWindow* window;
    BOOL hideTitlebar;
    BOOL hideButtons;
    BOOL useTitlebarColor;
    BOOL transitioning;
    BOOL originalFullSizeContent;
    BOOL originalTransparent;
    NSWindowTitleVisibility originalTitleVisibility;
}
- (instancetype)initWithWindow:(NSWindow*)nativeWindow;
- (void)setHidden:(BOOL)hidden buttonsHidden:(BOOL)buttonsHidden colored:(BOOL)colored;
- (void)apply;
@end

@implementation SioyekTitlebarController

- (instancetype)initWithWindow:(NSWindow*)nativeWindow {
    self = [super init];
    if (self) {
        window = nativeWindow;
        originalFullSizeContent = (window.styleMask & NSWindowStyleMaskFullSizeContentView) != 0;
        originalTransparent = window.titlebarAppearsTransparent;
        originalTitleVisibility = window.titleVisibility;
        NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(willChangeFullscreen:)
                       name:NSWindowWillEnterFullScreenNotification object:window];
        [center addObserver:self selector:@selector(willChangeFullscreen:)
                       name:NSWindowWillExitFullScreenNotification object:window];
        [center addObserver:self selector:@selector(didChangeFullscreen:)
                       name:NSWindowDidEnterFullScreenNotification object:window];
        [center addObserver:self selector:@selector(didChangeFullscreen:)
                       name:NSWindowDidExitFullScreenNotification object:window];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)setHidden:(BOOL)hidden buttonsHidden:(BOOL)buttonsHidden colored:(BOOL)colored {
    hideTitlebar = hidden;
    hideButtons = buttonsHidden;
    useTitlebarColor = colored;
    [self apply];
}

- (void)willChangeFullscreen:(NSNotification*)notification {
    transitioning = YES;
    // AppKit owns the titlebar during the native fullscreen animation.
    for (NSNumber* button in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        [[window standardWindowButton:(NSWindowButton)button.integerValue] setHidden:NO];
    }
}

- (void)didChangeFullscreen:(NSNotification*)notification {
    transitioning = NO;
    [self apply];
}

- (void)apply {
    if (transitioning) return;
    BOOL fullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (!fullscreen) {
        NSWindowStyleMask mask = window.styleMask;
        if (hideTitlebar || originalFullSizeContent) {
            mask |= NSWindowStyleMaskFullSizeContentView;
        } else {
            mask &= ~NSWindowStyleMaskFullSizeContentView;
        }
        // Keep the titled/resizable style, as kitty's titlebar-only mode does.
        // Changing Qt window flags would recreate the native window instead.
        if (mask != window.styleMask) {
            NSResponder* responder = [window.firstResponder retain];
            [window setStyleMask:mask];
            [window makeFirstResponder:responder];
            [responder release];
        }
        window.titleVisibility = hideTitlebar ? NSWindowTitleHidden : originalTitleVisibility;
        window.titlebarAppearsTransparent = hideTitlebar || useTitlebarColor || originalTransparent;
    }
    // Keep the system fullscreen controls available, matching kitty.
    BOOL hidden = !fullscreen && (hideTitlebar || hideButtons);
    for (NSNumber* button in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        [[window standardWindowButton:(NSWindowButton)button.integerValue] setHidden:hidden];
    }
}

@end

extern "C" void setWindowTitleBarHidden(WId winId, bool hidden, bool buttonsHidden, bool colored) {
    if (winId == 0) return;
    NSWindow* window = [(NSView*)winId window];
    if (window == nil) return;

    static char titlebarControllerKey;
    SioyekTitlebarController* controller = objc_getAssociatedObject(window, &titlebarControllerKey);
    if (controller == nil) {
        controller = [[SioyekTitlebarController alloc] initWithWindow:window];
        objc_setAssociatedObject(window, &titlebarControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [controller release];
    }
    [controller setHidden:hidden buttonsHidden:buttonsHidden colored:colored];
}

#include <AppKit/AppKit.h>
#include <QWidget>
#include <QLayout>
#include <QMainWindow>
#include <QPointer>
#include <algorithm>
#include <vector>
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

struct TitlebarContent {
    QPointer<QWidget> widget;
    bool respectsSafeArea;
};

static char titlebarControllerKey;

@interface SioyekTitlebarController : NSObject {
    NSWindow* window;
    BOOL hideTitlebar;
    BOOL hideButtons;
    BOOL useTitlebarColor;
    BOOL transitioning;
    BOOL originalFullSizeContent;
    BOOL originalTransparent;
    NSWindowTitleVisibility originalTitleVisibility;
    std::vector<TitlebarContent> contentWidgets;
}
- (instancetype)initWithWindow:(NSWindow*)nativeWindow widget:(QWidget*)widget;
- (void)setHidden:(BOOL)hidden buttonsHidden:(BOOL)buttonsHidden colored:(BOOL)colored;
- (void)setContentExtended:(BOOL)extended;
- (void)addContent:(QWidget*)widget;
- (void)apply;
@end

@implementation SioyekTitlebarController

- (instancetype)initWithWindow:(NSWindow*)nativeWindow widget:(QWidget*)widget {
    self = [super init];
    if (self) {
        window = nativeWindow;
        originalFullSizeContent = (window.styleMask & NSWindowStyleMaskFullSizeContentView) != 0;
        originalTransparent = window.titlebarAppearsTransparent;
        originalTitleVisibility = window.titleVisibility;
        [self addContent:widget];
        if (auto mainWindow = qobject_cast<QMainWindow*>(widget)) {
            [self addContent:mainWindow->centralWidget()];
        }
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
    [self setContentExtended:NO];
    // AppKit owns the titlebar during the native fullscreen animation.
    for (NSNumber* button in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        [[window standardWindowButton:(NSWindowButton)button.integerValue] setHidden:NO];
    }
}

- (void)didChangeFullscreen:(NSNotification*)notification {
    transitioning = NO;
    [self apply];
}

- (void)addContent:(QWidget*)widget {
    if (!widget) return;
    contentWidgets.erase(std::remove_if(contentWidgets.begin(), contentWidgets.end(),
        [](const TitlebarContent& content) { return content.widget.isNull(); }), contentWidgets.end());
    for (const auto& content : contentWidgets) {
        if (content.widget == widget) return;
    }
    contentWidgets.push_back({widget, widget->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea)});
}

- (void)setContentExtended:(BOOL)extended {
    auto updateMargins = [extended](QWidget* widget, bool originalSafeArea) {
        if (!widget) return;
        bool respectsSafeArea = !extended && originalSafeArea;
        if (widget->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea) == respectsSafeArea) return;
        // Qt reserves titlebar space even when AppKit extends the content view into it.
        widget->setAttribute(Qt::WA_ContentsMarginsRespectsSafeArea, respectsSafeArea);
        if (widget->layout()) {
            widget->layout()->invalidate();
            widget->layout()->activate();
        }
        widget->updateGeometry();
        widget->update();
    };
    for (const auto& content : contentWidgets) {
        updateMargins(content.widget.data(), content.respectsSafeArea);
    }
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
    // Fullscreen must retain Qt's screen safe area, including the camera housing.
    [self setContentExtended:hideTitlebar && !fullscreen];
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

    SioyekTitlebarController* controller = objc_getAssociatedObject(window, &titlebarControllerKey);
    if (controller == nil) {
        controller = [[SioyekTitlebarController alloc] initWithWindow:window widget:QWidget::find(winId)];
        objc_setAssociatedObject(window, &titlebarControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [controller release];
    }
    [controller setHidden:hidden buttonsHidden:buttonsHidden colored:colored];
}

extern "C" void registerWindowTitlebarContent(WId winId, QWidget* content) {
    NSWindow* window = [(NSView*)winId window];
    SioyekTitlebarController* controller = objc_getAssociatedObject(window, &titlebarControllerKey);
    Q_ASSERT(controller != nil);
    [controller addContent:content];
    [controller apply];
}

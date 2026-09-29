#include <AppKit/AppKit.h>
#include <QWidget>
#include <QLayout>
#include <QEvent>
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

class TitlebarContentController : public QObject {
    struct Content {
        QPointer<QWidget> widget;
        bool respectsSafeArea;
    };
    QPointer<QWidget> window;
    std::vector<Content> contents;
    bool extended = false;
    bool updating = false;

    static void updateMargins(QWidget* widget, bool respectsSafeArea) {
        if (widget->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea) == respectsSafeArea) return;
        widget->setAttribute(Qt::WA_ContentsMarginsRespectsSafeArea, respectsSafeArea);
        if (widget->layout()) {
            widget->layout()->invalidate();
            widget->layout()->activate();
        }
        widget->updateGeometry();
        widget->update();
    }

    void sync() {
        if (!window || updating) return;
        updating = true;
        contents.erase(std::remove_if(contents.begin(), contents.end(), [this](const Content& content) {
            if (!content.widget) return true;
            if (content.widget->window() == window) return false;
            content.widget->removeEventFilter(this);
            updateMargins(content.widget, content.respectsSafeArea);
            return true;
        }), contents.end());

        auto widgets = window->findChildren<QWidget*>();
        widgets.prepend(window);
        for (QWidget* widget : widgets) {
            // Dialogs, native menus and other top-level windows own their own geometry.
            if (widget->window() != window) continue;
            auto found = std::find_if(contents.begin(), contents.end(), [widget](const Content& content) {
                return content.widget == widget;
            });
            if (found == contents.end()) {
                contents.push_back({widget, widget->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea)});
                widget->installEventFilter(this);
            }
        }
        // Nested layouts and overlays can each add the titlebar inset independently.
        for (const auto& content : contents) {
            if (content.widget) updateMargins(content.widget, !extended && content.respectsSafeArea);
        }
        updating = false;
    }

    bool eventFilter(QObject* object, QEvent* event) override {
        if (event->type() == QEvent::ChildPolished || event->type() == QEvent::Show
            || event->type() == QEvent::ParentChange) {
            sync();
        }
        return QObject::eventFilter(object, event);
    }

public:
    explicit TitlebarContentController(QWidget* widget) : QObject(widget), window(widget) {
        sync();
    }

    void setExtended(bool value) {
        extended = value;
        sync();
    }
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
    QPointer<TitlebarContentController> contentController;
}
- (instancetype)initWithWindow:(NSWindow*)nativeWindow widget:(QWidget*)widget;
- (void)setHidden:(BOOL)hidden buttonsHidden:(BOOL)buttonsHidden colored:(BOOL)colored;
- (void)setContentExtended:(BOOL)extended;
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
        contentController = new TitlebarContentController(widget);
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
    delete contentController.data();
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

- (void)setContentExtended:(BOOL)extended {
    if (contentController) contentController->setExtended(extended);
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

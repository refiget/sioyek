#import <AppKit/AppKit.h>
#include <QApplication>
#include <QLineEdit>
#include <QMainWindow>
#include <QMenuBar>
#include <QTest>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QSignalSpy>
#include <QSortFilterProxyModel>
#include <QStringListModel>
#include <QTableView>

extern "C" void setWindowTitleBarHidden(WId, bool, bool, bool);
extern "C" void registerWindowTitlebarContent(WId, QWidget*);

static void require(bool condition, const char* message) {
    if (!condition) qFatal("%s", message);
}

static void settle() {
    QTest::qWait(100);
}

static void checkButtons(NSWindow* window, bool hidden) {
    for (NSNumber* type in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)]) {
        require([window standardWindowButton:(NSWindowButton)type.integerValue].hidden == hidden,
                "Unexpected traffic-light visibility");
    }
}

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QMainWindow main;
    auto content = new QWidget;
    auto layout = new QVBoxLayout(content);
    layout->setContentsMargins(0, 0, 0, 0);
    auto document = new QWidget;
    layout->addWidget(document);
    main.setCentralWidget(content);
    main.menuBar()->addMenu("File");
    QWidget commandContainer(&main);
    auto commandLayout = new QHBoxLayout(&commandContainer);
    commandLayout->setContentsMargins(10, 0, 10, 0);
    QLineEdit command;
    commandLayout->addWidget(&command);
    commandContainer.setGeometry(0, 0, 300, 30);
    QSignalSpy submitted(&command, &QLineEdit::returnPressed);
    main.resize(640, 480);
    main.show();
    commandContainer.show();
    command.setFocus();
    settle();

    NSWindow* native = [(NSView*)main.winId() window];
    const auto originalMask = native.styleMask;
    const auto originalVisibility = native.titleVisibility;
    const bool originalTransparent = native.titlebarAppearsTransparent;
    const NSWindowStyleMask controls = NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
        | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;

    for (int i = 0; i < 3; ++i) {
        setWindowTitleBarHidden(main.winId(), true, false, false);
        registerWindowTitlebarContent(main.winId(), &commandContainer);
        settle();
        require(document->mapTo(&main, QPoint(0, 0)).y() == 0, "Document still has a top gutter");
        require(content->geometry() == main.rect(), "Document container does not fill the window");
        require((native.styleMask & controls) == (originalMask & controls), "Native window controls changed");
        require(native.styleMask & NSWindowStyleMaskFullSizeContentView, "Full-size content flag missing");
        require(main.focusWidget() == &command, "Titlebar toggle lost command focus");
        require(commandContainer.contentsMargins().top() == 0, "Command container retained titlebar padding");
        require(command.height() >= command.sizeHint().height(), "Command input is clipped");
        require(commandContainer.rect().contains(command.geometry()), "Command input extends outside its container");
        command.clear();
        QTest::keyClicks(&command, "goto_page");
        QTest::keyClick(&command, Qt::Key_Return);
        require(command.text() == "goto_page" && submitted.count() == i + 1, "Command typing or Return failed");
        checkButtons(native, true);
        main.resize(700 + i * 20, 500 + i * 20);
        settle();
        require(content->geometry() == main.rect(), "Content failed to follow window resize");

        // Exercise the notification policy without pretending to emulate a display's fullscreen animation.
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowWillEnterFullScreenNotification object:native];
        require(main.testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Fullscreen did not restore window safe area");
        require(content->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Fullscreen did not restore content safe area");
        require(commandContainer.testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Fullscreen did not restore command safe area");
        checkButtons(native, false);
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidExitFullScreenNotification object:native];
        settle();
        require(document->mapTo(&main, QPoint(0, 0)).y() == 0, "Top gutter returned after fullscreen notification");

        setWindowTitleBarHidden(main.winId(), false, false, false);
        settle();
        require(native.styleMask == originalMask, "Original window style was not restored");
        require(native.titleVisibility == originalVisibility, "Original title visibility was not restored");
        require(native.titlebarAppearsTransparent == originalTransparent, "Original transparency was not restored");
        require(main.testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Window safe area was not restored");
        require(content->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Content safe area was not restored");
        require(commandContainer.testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Command safe area was not restored");
        checkButtons(native, false);
    }

    setWindowTitleBarHidden(main.winId(), false, true, false);
    require(native.styleMask == originalMask, "Buttons-only setting changed the window style");
    require(content->testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Buttons-only setting changed content margins");
    checkButtons(native, true);

    setWindowTitleBarHidden(main.winId(), true, false, false);
    {
        // Command palettes are created after the window, with their own filter/list layout.
        QWidget palette(&main);
        auto paletteLayout = new QVBoxLayout(&palette);
        QLineEdit filter;
        QTableView commands;
        QStringListModel names({"goto_page", "toggle_titlebar", "toggle_statusbar"});
        QSortFilterProxyModel filtered;
        filtered.setSourceModel(&names);
        commands.setModel(&filtered);
        paletteLayout->addWidget(&filter);
        paletteLayout->addWidget(&commands);
        QObject::connect(&filter, &QLineEdit::textChanged, &filtered, &QSortFilterProxyModel::setFilterFixedString);
        palette.setGeometry(50, 0, 400, 300);
        registerWindowTitlebarContent(main.winId(), &palette);
        palette.show();
        palette.raise();
        filter.setFocus();
        settle();
        require(palette.contentsMargins().top() == 0, "Palette retained titlebar padding");
        require(palette.rect().contains(filter.geometry()), "Palette filter is clipped");
        QTest::keyClicks(&filter, "toggle");
        require(filtered.rowCount() == 2, "Palette filtering failed");
        setWindowTitleBarHidden(main.winId(), false, false, false);
        setWindowTitleBarHidden(main.winId(), true, false, false);
        settle();
        require(main.focusWidget() == &filter && filter.text() == "toggle", "Palette lost focus or text on toggle");
        require(palette.contentsMargins().top() == 0, "Palette padding returned after toggle");
    }
    // Closed panels must not leave dangling pointers in the titlebar controller.
    setWindowTitleBarHidden(main.winId(), false, false, false);

    QWidget helper;
    helper.setAttribute(Qt::WA_ContentsMarginsRespectsSafeArea, false);
    helper.show();
    setWindowTitleBarHidden(helper.winId(), true, false, false);
    setWindowTitleBarHidden(helper.winId(), false, false, false);
    require(!helper.testAttribute(Qt::WA_ContentsMarginsRespectsSafeArea), "Helper's original margin policy was not preserved");
    require(![[(NSView*)helper.winId() window] standardWindowButton:NSWindowCloseButton].hidden,
            "Helper's buttons were not restored");
    qInfo("macOS titlebar layout regression checks passed");
    return 0;
}

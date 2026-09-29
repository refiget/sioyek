QT += widgets testlib
CONFIG += console c++17
CONFIG -= app_bundle
TARGET = titlebar_regression
QMAKE_MACOSX_DEPLOYMENT_TARGET = 15
LIBS += -framework AppKit
OBJECTIVE_SOURCES += titlebar.mm ../../pdf_viewer/macos_specific.mm

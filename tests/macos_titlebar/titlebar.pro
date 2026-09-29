QT += widgets testlib
CONFIG += console c++17
CONFIG -= app_bundle
TARGET = titlebar_regression
OBJECTIVE_SOURCES += titlebar.mm ../../pdf_viewer/macos_specific.mm

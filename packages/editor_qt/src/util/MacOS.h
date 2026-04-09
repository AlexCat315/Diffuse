#pragma once

#include <cstdint>
#include <QtCore/qglobal.h>

/// Get the native NSView* for a Qt widget on macOS
uint64_t getQtWidgetNSView(quintptr qtWinId);

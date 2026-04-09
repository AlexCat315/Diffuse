#include "Theme.h"

#include <QFile>
#include <QPalette>
#include <QStyleFactory>

void Theme::apply(QApplication* app)
{
    // Use Fusion style as base (cross-platform, QSS-friendly)
    app->setStyle(QStyleFactory::create("Fusion"));

    // Catppuccin Mocha color palette
    QPalette palette;

    // Core colors
    QColor base(0x1E, 0x1E, 0x2E);       // Base
    QColor mantle(0x18, 0x18, 0x25);      // Mantle
    QColor crust(0x11, 0x11, 0x1B);       // Crust
    QColor surface0(0x31, 0x32, 0x44);    // Surface0
    QColor surface1(0x45, 0x47, 0x5A);    // Surface1
    QColor surface2(0x58, 0x5B, 0x70);    // Surface2
    QColor overlay0(0x6C, 0x70, 0x86);    // Overlay0
    QColor text(0xCD, 0xD6, 0xF4);        // Text
    QColor subtext1(0xBA, 0xC2, 0xDE);    // Subtext1
    QColor subtext0(0xA6, 0xAD, 0xC8);    // Subtext0
    QColor blue(0x89, 0xB4, 0xFA);        // Blue (accent)
    QColor red(0xF3, 0x8B, 0xA8);         // Red
    QColor green(0xA6, 0xE3, 0xA1);       // Green
    QColor yellow(0xF9, 0xE2, 0xAF);      // Yellow
    QColor lavender(0xB4, 0xBE, 0xFE);    // Lavender

    // Active palette
    palette.setColor(QPalette::Window, base);
    palette.setColor(QPalette::WindowText, text);
    palette.setColor(QPalette::Base, mantle);
    palette.setColor(QPalette::AlternateBase, surface0);
    palette.setColor(QPalette::ToolTipBase, surface0);
    palette.setColor(QPalette::ToolTipText, text);
    palette.setColor(QPalette::PlaceholderText, overlay0);
    palette.setColor(QPalette::Text, text);
    palette.setColor(QPalette::Button, surface0);
    palette.setColor(QPalette::ButtonText, text);
    palette.setColor(QPalette::BrightText, lavender);
    palette.setColor(QPalette::Highlight, blue);
    palette.setColor(QPalette::HighlightedText, crust);
    palette.setColor(QPalette::Link, blue);
    palette.setColor(QPalette::LinkVisited, lavender);
    palette.setColor(QPalette::Light, surface1);
    palette.setColor(QPalette::Midlight, surface0);
    palette.setColor(QPalette::Mid, surface2);
    palette.setColor(QPalette::Dark, mantle);
    palette.setColor(QPalette::Shadow, crust);

    // Disabled palette
    palette.setColor(QPalette::Disabled, QPalette::WindowText, overlay0);
    palette.setColor(QPalette::Disabled, QPalette::Text, overlay0);
    palette.setColor(QPalette::Disabled, QPalette::ButtonText, overlay0);
    palette.setColor(QPalette::Disabled, QPalette::Highlight, surface1);
    palette.setColor(QPalette::Disabled, QPalette::HighlightedText, overlay0);

    app->setPalette(palette);

    // Load QSS for fine details
    QFile qss(":/themes/catppuccin-mocha.qss");
    if (qss.open(QIODevice::ReadOnly | QIODevice::Text)) {
        app->setStyleSheet(QString::fromUtf8(qss.readAll()));
    }
}

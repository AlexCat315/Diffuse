#pragma once

#include <QString>
#include <QIcon>
#include <QPixmap>

/**
 * IconProvider — Central management of SVG icons from resources.
 *
 * Provides icon factory methods organized by functional category:
 * - File & Scene operations
 * - Undo/Redo
 * - Playback controls
 * - Gizmo/Transform tools
 * - UI components
 * - Asset types
 * - Viewport & shading
 * - Scene objects and colliders
 *
 * All icons are loaded from resources using Qt's resource system (:/icons/...).
 * Icons can be applied to buttons, actions, and labels with consistent theming.
 *
 * Usage:
 *   auto saveIcon = IconProvider::save();
 *   auto undoIcon = IconProvider::undo();
 *   auto playIcon = IconProvider::play();
 *   action->setIcon(playIcon);
 */
class IconProvider
{
public:
    // ── File & Scene ──────────────────────────────────────────
    static QIcon save();
    static QIcon openFolder();
    static QIcon folder();
    static QIcon document();
    static QIcon packageIcon();

    // ── Undo / Redo ───────────────────────────────────────────
    static QIcon undo();
    static QIcon redo();

    // ── Playback ──────────────────────────────────────────────
    static QIcon play();
    static QIcon pause();
    static QIcon stop();
    static QIcon forward();

    // ── Gizmo / Transform ─────────────────────────────────────
    static QIcon translate();
    static QIcon rotate();
    static QIcon scale();
    static QIcon cursor();
    static QIcon crosshair();

    // ── UI Actions ────────────────────────────────────────────
    static QIcon close();
    static QIcon refresh();
    static QIcon chevronUp();
    static QIcon chevronDown();
    static QIcon chevronRight();
    static QIcon plus();
    static QIcon deleteIcon();
    static QIcon check();

    // ── Asset Types ───────────────────────────────────────────
    static QIcon model();
    static QIcon texture();
    static QIcon shader();
    static QIcon scene();
    static QIcon script();
    static QIcon audio();
    static QIcon material();
    static QIcon animation();

    // ── Viewport & Shading ────────────────────────────────────
    static QIcon eye();
    static QIcon eyeSlash();
    static QIcon wireframe();
    static QIcon lightBulb();

    // ── Scene Objects ─────────────────────────────────────────
    static QIcon camera();
    static QIcon box();
    static QIcon lightSpot();
    static QIcon lightSun();
    static QIcon lightPoint();
    static QIcon settings();
    static QIcon lockClosed();
    static QIcon lockOpen();

    // ── Colliders ─────────────────────────────────────────────
    static QIcon boxCollider();
    static QIcon sphereCollider();
    static QIcon meshCollider();
    static QIcon capsuleCollider();
    static QIcon filledCircle();

    // ── Navigation ────────────────────────────────────────────
    static QIcon triangleRight();
    static QIcon triangleDown();
    static QIcon arrowUp();
    static QIcon list();
    static QIcon grid();

    // ── Misc ──────────────────────────────────────────────────
    static QIcon globe();
    static QIcon data();
    static QIcon about();
    static QIcon keyboard();
    static QIcon remote();

private:
    // Helper: Load SVG from resource path
    static QPixmap loadSvg(const QString& filename, int size = 16);
};

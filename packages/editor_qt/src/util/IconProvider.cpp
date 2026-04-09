#include "IconProvider.h"

#include <QtSvg/QSvgRenderer>
#include <QPainter>
#include <QDebug>

// ── Helper: Load SVG with size ─────────────────────────────────────────

QPixmap IconProvider::loadSvg(const QString& filename, int size)
{
    const QString resourcePath = ":/icons/" + filename;
    
    QSvgRenderer renderer(resourcePath);
    if (!renderer.isValid()) {
        qWarning() << "[IconProvider] Failed to load SVG:" << resourcePath;
        return QPixmap();
    }
    
    QPixmap pixmap(size, size);
    pixmap.fill(Qt::transparent);
    
    QPainter painter(&pixmap);
    renderer.render(&painter);
    painter.end();
    
    return pixmap;
}

// ── File & Scene ───────────────────────────────────────────────────────

QIcon IconProvider::save() {
    return QIcon(loadSvg("save.svg"));
}

QIcon IconProvider::openFolder() {
    return QIcon(loadSvg("folder-f.svg"));
}

QIcon IconProvider::folder() {
    return QIcon(loadSvg("folder.svg"));
}

QIcon IconProvider::document() {
    return QIcon(loadSvg("document-text.svg"));
}

QIcon IconProvider::packageIcon() {
    return QIcon(loadSvg("package.svg"));
}

// ── Undo / Redo ────────────────────────────────────────────────────────

QIcon IconProvider::undo() {
    return QIcon(loadSvg("undo.svg"));
}

QIcon IconProvider::redo() {
    return QIcon(loadSvg("redo.svg"));
}

// ── Playback ───────────────────────────────────────────────────────────

QIcon IconProvider::play() {
    return QIcon(loadSvg("play.svg"));
}

QIcon IconProvider::pause() {
    return QIcon(loadSvg("pause.svg"));
}

QIcon IconProvider::stop() {
    return QIcon(loadSvg("stop.svg"));
}

QIcon IconProvider::forward() {
    return QIcon(loadSvg("forward.svg"));
}

// ── Gizmo / Transform ──────────────────────────────────────────────────

QIcon IconProvider::translate() {
    return QIcon(loadSvg("direction-arrows.svg"));
}

QIcon IconProvider::rotate() {
    return QIcon(loadSvg("arrow-path.svg"));
}

QIcon IconProvider::scale() {
    return QIcon(loadSvg("arrows-pointing-out.svg"));
}

QIcon IconProvider::cursor() {
    return QIcon(loadSvg("cursor-arrow-rays.svg"));
}

QIcon IconProvider::crosshair() {
    return QIcon(loadSvg("crosshair.svg"));
}

// ── UI Actions ────────────────────────────────────────────────────────

QIcon IconProvider::close() {
    return QIcon(loadSvg("x-mark.svg"));
}

QIcon IconProvider::refresh() {
    return QIcon(loadSvg("refresh.svg"));
}

QIcon IconProvider::chevronUp() {
    return QIcon(loadSvg("chevron-up.svg"));
}

QIcon IconProvider::chevronDown() {
    return QIcon(loadSvg("chevron-down.svg"));
}

QIcon IconProvider::chevronRight() {
    return QIcon(loadSvg("chevron-right.svg"));
}

QIcon IconProvider::plus() {
    return QIcon(loadSvg("plus.svg"));
}

QIcon IconProvider::deleteIcon() {
    return QIcon(loadSvg("delete.svg"));
}

QIcon IconProvider::check() {
    return QIcon(loadSvg("check.svg"));
}

// ── Asset Types ────────────────────────────────────────────────────────

QIcon IconProvider::model() {
    return QIcon(loadSvg("cube.svg"));
}

QIcon IconProvider::texture() {
    return QIcon(loadSvg("photo.svg"));
}

QIcon IconProvider::shader() {
    return QIcon(loadSvg("sparkle.svg"));
}

QIcon IconProvider::scene() {
    return QIcon(loadSvg("film.svg"));
}

QIcon IconProvider::script() {
    return QIcon(loadSvg("code-bracket.svg"));
}

QIcon IconProvider::audio() {
    return QIcon(loadSvg("mic.svg"));
}

QIcon IconProvider::material() {
    return QIcon(loadSvg("paint-brush.svg"));
}

QIcon IconProvider::animation() {
    return QIcon(loadSvg("clock.svg"));
}

// ── Viewport & Shading ────────────────────────────────────────────────

QIcon IconProvider::eye() {
    return QIcon(loadSvg("eye.svg"));
}

QIcon IconProvider::eyeSlash() {
    return QIcon(loadSvg("eye-slash.svg"));
}

QIcon IconProvider::wireframe() {
    return QIcon(loadSvg("grid-pattern.svg"));
}

QIcon IconProvider::lightBulb() {
    return QIcon(loadSvg("light-bulb.svg"));
}

// ── Scene Objects ──────────────────────────────────────────────────────

QIcon IconProvider::camera() {
    return QIcon(loadSvg("camera.svg"));
}

QIcon IconProvider::box() {
    return QIcon(loadSvg("box.svg"));
}

QIcon IconProvider::lightSpot() {
    return QIcon(loadSvg("light_spot.svg"));
}

QIcon IconProvider::lightSun() {
    return QIcon(loadSvg("light_sun.svg"));
}

QIcon IconProvider::lightPoint() {
    return QIcon(loadSvg("light_point.svg"));
}

QIcon IconProvider::settings() {
    return QIcon(loadSvg("cog-6-tooth.svg"));
}

QIcon IconProvider::lockClosed() {
    return QIcon(loadSvg("lock-closed.svg"));
}

QIcon IconProvider::lockOpen() {
    return QIcon(loadSvg("lock-open.svg"));
}

// ── Colliders ──────────────────────────────────────────────────────────

QIcon IconProvider::boxCollider() {
    return QIcon(loadSvg("box.svg"));
}

QIcon IconProvider::sphereCollider() {
    return QIcon(loadSvg("icon-sphere Collider.svg"));
}

QIcon IconProvider::meshCollider() {
    return QIcon(loadSvg("Mesh Collider.svg"));
}

QIcon IconProvider::capsuleCollider() {
    return QIcon(loadSvg("capsule-fill.svg"));
}

QIcon IconProvider::filledCircle() {
    return QIcon(loadSvg("icon-filled-circle.svg"));
}

// ── Navigation ────────────────────────────────────────────────────────

QIcon IconProvider::triangleRight() {
    return QIcon(loadSvg("triangle-right.svg"));
}

QIcon IconProvider::triangleDown() {
    return QIcon(loadSvg("triangle-down.svg"));
}

QIcon IconProvider::arrowUp() {
    return QIcon(loadSvg("arrow-big-up.svg"));
}

QIcon IconProvider::list() {
    return QIcon(loadSvg("list.svg"));
}

QIcon IconProvider::grid() {
    return QIcon(loadSvg("squares-2x2.svg"));
}

// ── Misc ───────────────────────────────────────────────────────────────

QIcon IconProvider::globe() {
    return QIcon(loadSvg("globe.svg"));
}

QIcon IconProvider::data() {
    return QIcon(loadSvg("data.svg"));
}

QIcon IconProvider::about() {
    return QIcon(loadSvg("about.svg"));
}

QIcon IconProvider::keyboard() {
    return QIcon(loadSvg("keyboard.svg"));
}

QIcon IconProvider::remote() {
    return QIcon(loadSvg("remote.svg"));
}

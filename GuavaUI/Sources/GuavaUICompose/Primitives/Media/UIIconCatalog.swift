import GuavaUIRuntime

/// The bundled icon set.
///
/// Every asset is authored on a 24x24 grid and drawn through
/// `renderingMode: .alphaMask`, so the alpha channel becomes coverage and
/// the foreground color becomes the fill. Icons therefore follow theme
/// tokens instead of their authored colors, and one asset serves every
/// density.
///
/// Glyphs that are routinely drawn at 8-14px (`chevron-*`, `check`, `x`,
/// `plus`, `minus`) are authored with a heavier stroke so they stay
/// legible when scaled down; everything else uses the 2.0 default.
///
/// ```swift
/// Icon(UIIcons.Navigation.chevronDown, size: 12, color: .onSurfaceMuted)
/// Icon(UIIcons.Status.starFill, size: 16, color: .warning)
/// ```
public enum UIIcons {
    private static func asset(_ name: String) -> BundleImageResource {
        BundleImageResource.svg(named: name,
                                 in: GuavaUIComposeResourceBundle.bundle,
                                 subdirectory: "UIIcons")
    }

    // MARK: - Navigation
    public enum Navigation {
        public static let arrowDown = asset("arrow-down")
        public static let arrowDownRight = asset("arrow-down-right")
        public static let arrowLeft = asset("arrow-left")
        public static let arrowRight = asset("arrow-right")
        public static let arrowUp = asset("arrow-up")
        public static let arrowUpRight = asset("arrow-up-right")
        public static let chevronDown = asset("chevron-down")
        public static let chevronLeft = asset("chevron-left")
        public static let chevronRight = asset("chevron-right")
        public static let chevronUp = asset("chevron-up")
        public static let chevronsLeft = asset("chevrons-left")
        public static let chevronsRight = asset("chevrons-right")
        public static let chevronsUpDown = asset("chevrons-up-down")
        public static let circleArrowDown = asset("circle-arrow-down")
        public static let circleArrowUp = asset("circle-arrow-up")
        public static let cornerDownRight = asset("corner-down-right")
        public static let expand = asset("expand")
        public static let fullscreen = asset("fullscreen")
        public static let maximize = asset("maximize")
        public static let menu = asset("menu")
        public static let minimize = asset("minimize")
        public static let moveRight = asset("move-right")
        public static let refresh = asset("refresh")
        public static let rotateCcw = asset("rotate-ccw")
        public static let rotateCw = asset("rotate-cw")
        public static let shrink = asset("shrink")
    }

    // MARK: - Action
    public enum Action {
        public static let check = asset("check")
        public static let checkCheck = asset("check-check")
        public static let clipboard = asset("clipboard")
        public static let copy = asset("copy")
        public static let crosshair = asset("crosshair")
        public static let download = asset("download")
        public static let externalLink = asset("external-link")
        public static let filter = asset("filter")
        public static let focus = asset("focus")
        public static let format = asset("format")
        public static let formatJson = asset("format-json")
        public static let grip = asset("grip")
        public static let link = asset("link")
        public static let minus = asset("minus")
        public static let moreHorizontal = asset("more-horizontal")
        public static let moreVertical = asset("more-vertical")
        public static let pencil = asset("pencil")
        public static let plus = asset("plus")
        public static let power = asset("power")
        public static let redo = asset("redo")
        public static let reset = asset("reset")
        public static let revert = asset("revert")
        public static let scissors = asset("scissors")
        public static let search = asset("search")
        public static let settings = asset("settings")
        public static let share = asset("share")
        public static let sliders = asset("sliders")
        public static let sortAsc = asset("sort-asc")
        public static let sortDesc = asset("sort-desc")
        public static let target = asset("target")
        public static let trash = asset("trash")
        public static let undo = asset("undo")
        public static let unlink = asset("unlink")
        public static let upload = asset("upload")
        public static let x = asset("x")
        public static let zoomIn = asset("zoom-in")
        public static let zoomOut = asset("zoom-out")
    }

    // MARK: - Status
    public enum Status {
        public static let alertCircle = asset("alert-circle")
        public static let alertOctagon = asset("alert-octagon")
        public static let alertTriangle = asset("alert-triangle")
        public static let bell = asset("bell")
        public static let bellOff = asset("bell-off")
        public static let bookmark = asset("bookmark")
        public static let checkCircle = asset("check-circle")
        public static let eye = asset("eye")
        public static let eyeOff = asset("eye-off")
        public static let flag = asset("flag")
        public static let heart = asset("heart")
        public static let heartFill = asset("heart-fill")
        public static let help = asset("help")
        public static let info = asset("info")
        public static let loader = asset("loader")
        public static let lock = asset("lock")
        public static let shield = asset("shield")
        public static let shieldCheck = asset("shield-check")
        public static let sparkles = asset("sparkles")
        public static let star = asset("star")
        public static let starFill = asset("star-fill")
        public static let unlock = asset("unlock")
        public static let xCircle = asset("x-circle")
        public static let zap = asset("zap")
    }

    // MARK: - File
    public enum File {
        public static let archive = asset("archive")
        public static let file = asset("file")
        public static let fileCode = asset("file-code")
        public static let filePlus = asset("file-plus")
        public static let fileText = asset("file-text")
        public static let folder = asset("folder")
        public static let folderOpen = asset("folder-open")
        public static let folderPlus = asset("folder-plus")
        public static let inbox = asset("inbox")
        public static let package = asset("package")
        public static let save = asset("save")
    }

    // MARK: - Editor
    public enum Editor {
        public static let box = asset("box")
        public static let brackets = asset("brackets")
        public static let brush = asset("brush")
        public static let bug = asset("bug")
        public static let code = asset("code")
        public static let compass = asset("compass")
        public static let eraser = asset("eraser")
        public static let gamepad = asset("gamepad")
        public static let gitBranch = asset("git-branch")
        public static let gitCommit = asset("git-commit")
        public static let gitCompare = asset("git-compare")
        public static let gitMerge = asset("git-merge")
        public static let hammer = asset("hammer")
        public static let layers = asset("layers")
        public static let lightbulb = asset("lightbulb")
        public static let mapPin = asset("map-pin")
        public static let pause = asset("pause")
        public static let play = asset("play")
        public static let `repeat` = asset("repeat")
        public static let shuffle = asset("shuffle")
        public static let skipBack = asset("skip-back")
        public static let skipForward = asset("skip-forward")
        public static let stop = asset("stop")
        public static let terminal = asset("terminal")
        public static let wrench = asset("wrench")
    }

    // MARK: - Layout
    public enum Layout {
        public static let columns2 = asset("columns-2")
        public static let columns3 = asset("columns-3")
        public static let dashboard = asset("dashboard")
        public static let grid = asset("grid")
        public static let indent = asset("indent")
        public static let outdent = asset("outdent")
        public static let panelBottom = asset("panel-bottom")
        public static let panelLeft = asset("panel-left")
        public static let panelRight = asset("panel-right")
        public static let panelTop = asset("panel-top")
        public static let rows2 = asset("rows-2")
        public static let rows3 = asset("rows-3")
        public static let sidebar = asset("sidebar")
        public static let table = asset("table")
    }

    // MARK: - Data
    public enum Data {
        public static let activity = asset("activity")
        public static let calendar = asset("calendar")
        public static let chartBar = asset("chart-bar")
        public static let chartLine = asset("chart-line")
        public static let chartPie = asset("chart-pie")
        public static let clock = asset("clock")
        public static let hourglass = asset("hourglass")
        public static let timer = asset("timer")
        public static let trendingDown = asset("trending-down")
        public static let trendingUp = asset("trending-up")
    }

    // MARK: - Media
    public enum Media {
        public static let camera = asset("camera")
        public static let image = asset("image")
        public static let mic = asset("mic")
        public static let monitor = asset("monitor")
        public static let music = asset("music")
        public static let video = asset("video")
        public static let volume = asset("volume")
        public static let volumeX = asset("volume-x")
    }

    // MARK: - Device
    public enum Device {
        public static let battery = asset("battery")
        public static let bluetooth = asset("bluetooth")
        public static let cloud = asset("cloud")
        public static let cloudDownload = asset("cloud-download")
        public static let cloudUpload = asset("cloud-upload")
        public static let cpu = asset("cpu")
        public static let database = asset("database")
        public static let hardDrive = asset("hard-drive")
        public static let moon = asset("moon")
        public static let server = asset("server")
        public static let sun = asset("sun")
        public static let wifi = asset("wifi")
    }

    // MARK: - User
    public enum User {
        public static let circleUser = asset("circle-user")
        public static let user = asset("user")
        public static let userPlus = asset("user-plus")
        public static let users = asset("users")
    }

    // MARK: - Text
    public enum Text {
        public static let alignCenter = asset("align-center")
        public static let alignLeft = asset("align-left")
        public static let alignRight = asset("align-right")
        public static let bold = asset("bold")
        public static let heading = asset("heading")
        public static let italic = asset("italic")
        public static let list = asset("list")
        public static let listOrdered = asset("list-ordered")
        public static let pilcrow = asset("pilcrow")
        public static let `type` = asset("type")
        public static let underline = asset("underline")
        public static let wrapText = asset("wrap-text")
    }

    // MARK: - Shape
    public enum Shape {
        public static let atSign = asset("at-sign")
        public static let bookOpen = asset("book-open")
        public static let circle = asset("circle")
        public static let circleDot = asset("circle-dot")
        public static let circleMinus = asset("circle-minus")
        public static let circlePlus = asset("circle-plus")
        public static let dot = asset("dot")
        public static let globe = asset("globe")
        public static let hash = asset("hash")
        public static let home = asset("home")
        public static let key = asset("key")
        public static let logIn = asset("log-in")
        public static let logOut = asset("log-out")
        public static let mail = asset("mail")
        public static let messageCircle = asset("message-circle")
        public static let messageSquare = asset("message-square")
        public static let paperclip = asset("paperclip")
        public static let pin = asset("pin")
        public static let pinOff = asset("pin-off")
        public static let send = asset("send")
        public static let square = asset("square")
        public static let squareCheck = asset("square-check")
        public static let tag = asset("tag")
        public static let triangle = asset("triangle")
    }

}

/// A browsable catalog entry. Used by tooling and the gallery to list
/// every bundled icon with its category for search and preview.
public struct UIIconEntry: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let category: String
    public let resource: BundleImageResource

    public init(id: String, name: String, category: String, resource: BundleImageResource) {
        self.id = id; self.name = name; self.category = category; self.resource = resource
    }
}

public extension UIIcons {
    /// Every bundled icon, grouped in catalog order.
    static let all: [UIIconEntry] = [
        UIIconEntry(id: "arrow-down", name: "arrow-down", category: "Navigation",
                     resource: Navigation.arrowDown),
        UIIconEntry(id: "arrow-down-right", name: "arrow-down-right", category: "Navigation",
                     resource: Navigation.arrowDownRight),
        UIIconEntry(id: "arrow-left", name: "arrow-left", category: "Navigation",
                     resource: Navigation.arrowLeft),
        UIIconEntry(id: "arrow-right", name: "arrow-right", category: "Navigation",
                     resource: Navigation.arrowRight),
        UIIconEntry(id: "arrow-up", name: "arrow-up", category: "Navigation",
                     resource: Navigation.arrowUp),
        UIIconEntry(id: "arrow-up-right", name: "arrow-up-right", category: "Navigation",
                     resource: Navigation.arrowUpRight),
        UIIconEntry(id: "chevron-down", name: "chevron-down", category: "Navigation",
                     resource: Navigation.chevronDown),
        UIIconEntry(id: "chevron-left", name: "chevron-left", category: "Navigation",
                     resource: Navigation.chevronLeft),
        UIIconEntry(id: "chevron-right", name: "chevron-right", category: "Navigation",
                     resource: Navigation.chevronRight),
        UIIconEntry(id: "chevron-up", name: "chevron-up", category: "Navigation",
                     resource: Navigation.chevronUp),
        UIIconEntry(id: "chevrons-left", name: "chevrons-left", category: "Navigation",
                     resource: Navigation.chevronsLeft),
        UIIconEntry(id: "chevrons-right", name: "chevrons-right", category: "Navigation",
                     resource: Navigation.chevronsRight),
        UIIconEntry(id: "chevrons-up-down", name: "chevrons-up-down", category: "Navigation",
                     resource: Navigation.chevronsUpDown),
        UIIconEntry(id: "circle-arrow-down", name: "circle-arrow-down", category: "Navigation",
                     resource: Navigation.circleArrowDown),
        UIIconEntry(id: "circle-arrow-up", name: "circle-arrow-up", category: "Navigation",
                     resource: Navigation.circleArrowUp),
        UIIconEntry(id: "corner-down-right", name: "corner-down-right", category: "Navigation",
                     resource: Navigation.cornerDownRight),
        UIIconEntry(id: "expand", name: "expand", category: "Navigation",
                     resource: Navigation.expand),
        UIIconEntry(id: "fullscreen", name: "fullscreen", category: "Navigation",
                     resource: Navigation.fullscreen),
        UIIconEntry(id: "maximize", name: "maximize", category: "Navigation",
                     resource: Navigation.maximize),
        UIIconEntry(id: "minimize", name: "minimize", category: "Navigation",
                     resource: Navigation.minimize),
        UIIconEntry(id: "move-right", name: "move-right", category: "Navigation",
                     resource: Navigation.moveRight),
        UIIconEntry(id: "refresh", name: "refresh", category: "Navigation",
                     resource: Navigation.refresh),
        UIIconEntry(id: "rotate-ccw", name: "rotate-ccw", category: "Navigation",
                     resource: Navigation.rotateCcw),
        UIIconEntry(id: "rotate-cw", name: "rotate-cw", category: "Navigation",
                     resource: Navigation.rotateCw),
        UIIconEntry(id: "shrink", name: "shrink", category: "Navigation",
                     resource: Navigation.shrink),
        UIIconEntry(id: "check", name: "check", category: "Action",
                     resource: Action.check),
        UIIconEntry(id: "check-check", name: "check-check", category: "Action",
                     resource: Action.checkCheck),
        UIIconEntry(id: "clipboard", name: "clipboard", category: "Action",
                     resource: Action.clipboard),
        UIIconEntry(id: "copy", name: "copy", category: "Action",
                     resource: Action.copy),
        UIIconEntry(id: "crosshair", name: "crosshair", category: "Action",
                     resource: Action.crosshair),
        UIIconEntry(id: "download", name: "download", category: "Action",
                     resource: Action.download),
        UIIconEntry(id: "external-link", name: "external-link", category: "Action",
                     resource: Action.externalLink),
        UIIconEntry(id: "filter", name: "filter", category: "Action",
                     resource: Action.filter),
        UIIconEntry(id: "focus", name: "focus", category: "Action",
                     resource: Action.focus),
        UIIconEntry(id: "format", name: "format", category: "Action",
                     resource: Action.format),
        UIIconEntry(id: "format-json", name: "format-json", category: "Action",
                     resource: Action.formatJson),
        UIIconEntry(id: "grip", name: "grip", category: "Action",
                     resource: Action.grip),
        UIIconEntry(id: "link", name: "link", category: "Action",
                     resource: Action.link),
        UIIconEntry(id: "minus", name: "minus", category: "Action",
                     resource: Action.minus),
        UIIconEntry(id: "more-horizontal", name: "more-horizontal", category: "Action",
                     resource: Action.moreHorizontal),
        UIIconEntry(id: "more-vertical", name: "more-vertical", category: "Action",
                     resource: Action.moreVertical),
        UIIconEntry(id: "pencil", name: "pencil", category: "Action",
                     resource: Action.pencil),
        UIIconEntry(id: "plus", name: "plus", category: "Action",
                     resource: Action.plus),
        UIIconEntry(id: "power", name: "power", category: "Action",
                     resource: Action.power),
        UIIconEntry(id: "redo", name: "redo", category: "Action",
                     resource: Action.redo),
        UIIconEntry(id: "reset", name: "reset", category: "Action",
                     resource: Action.reset),
        UIIconEntry(id: "revert", name: "revert", category: "Action",
                     resource: Action.revert),
        UIIconEntry(id: "scissors", name: "scissors", category: "Action",
                     resource: Action.scissors),
        UIIconEntry(id: "search", name: "search", category: "Action",
                     resource: Action.search),
        UIIconEntry(id: "settings", name: "settings", category: "Action",
                     resource: Action.settings),
        UIIconEntry(id: "share", name: "share", category: "Action",
                     resource: Action.share),
        UIIconEntry(id: "sliders", name: "sliders", category: "Action",
                     resource: Action.sliders),
        UIIconEntry(id: "sort-asc", name: "sort-asc", category: "Action",
                     resource: Action.sortAsc),
        UIIconEntry(id: "sort-desc", name: "sort-desc", category: "Action",
                     resource: Action.sortDesc),
        UIIconEntry(id: "target", name: "target", category: "Action",
                     resource: Action.target),
        UIIconEntry(id: "trash", name: "trash", category: "Action",
                     resource: Action.trash),
        UIIconEntry(id: "undo", name: "undo", category: "Action",
                     resource: Action.undo),
        UIIconEntry(id: "unlink", name: "unlink", category: "Action",
                     resource: Action.unlink),
        UIIconEntry(id: "upload", name: "upload", category: "Action",
                     resource: Action.upload),
        UIIconEntry(id: "x", name: "x", category: "Action",
                     resource: Action.x),
        UIIconEntry(id: "zoom-in", name: "zoom-in", category: "Action",
                     resource: Action.zoomIn),
        UIIconEntry(id: "zoom-out", name: "zoom-out", category: "Action",
                     resource: Action.zoomOut),
        UIIconEntry(id: "alert-circle", name: "alert-circle", category: "Status",
                     resource: Status.alertCircle),
        UIIconEntry(id: "alert-octagon", name: "alert-octagon", category: "Status",
                     resource: Status.alertOctagon),
        UIIconEntry(id: "alert-triangle", name: "alert-triangle", category: "Status",
                     resource: Status.alertTriangle),
        UIIconEntry(id: "bell", name: "bell", category: "Status",
                     resource: Status.bell),
        UIIconEntry(id: "bell-off", name: "bell-off", category: "Status",
                     resource: Status.bellOff),
        UIIconEntry(id: "bookmark", name: "bookmark", category: "Status",
                     resource: Status.bookmark),
        UIIconEntry(id: "check-circle", name: "check-circle", category: "Status",
                     resource: Status.checkCircle),
        UIIconEntry(id: "eye", name: "eye", category: "Status",
                     resource: Status.eye),
        UIIconEntry(id: "eye-off", name: "eye-off", category: "Status",
                     resource: Status.eyeOff),
        UIIconEntry(id: "flag", name: "flag", category: "Status",
                     resource: Status.flag),
        UIIconEntry(id: "heart", name: "heart", category: "Status",
                     resource: Status.heart),
        UIIconEntry(id: "help", name: "help", category: "Status",
                     resource: Status.help),
        UIIconEntry(id: "info", name: "info", category: "Status",
                     resource: Status.info),
        UIIconEntry(id: "loader", name: "loader", category: "Status",
                     resource: Status.loader),
        UIIconEntry(id: "lock", name: "lock", category: "Status",
                     resource: Status.lock),
        UIIconEntry(id: "shield", name: "shield", category: "Status",
                     resource: Status.shield),
        UIIconEntry(id: "shield-check", name: "shield-check", category: "Status",
                     resource: Status.shieldCheck),
        UIIconEntry(id: "sparkles", name: "sparkles", category: "Status",
                     resource: Status.sparkles),
        UIIconEntry(id: "star", name: "star", category: "Status",
                     resource: Status.star),
        UIIconEntry(id: "star-fill", name: "star-fill", category: "Status",
                     resource: Status.starFill),
        UIIconEntry(id: "unlock", name: "unlock", category: "Status",
                     resource: Status.unlock),
        UIIconEntry(id: "x-circle", name: "x-circle", category: "Status",
                     resource: Status.xCircle),
        UIIconEntry(id: "zap", name: "zap", category: "Status",
                     resource: Status.zap),
        UIIconEntry(id: "archive", name: "archive", category: "File",
                     resource: File.archive),
        UIIconEntry(id: "file", name: "file", category: "File",
                     resource: File.file),
        UIIconEntry(id: "file-code", name: "file-code", category: "File",
                     resource: File.fileCode),
        UIIconEntry(id: "file-plus", name: "file-plus", category: "File",
                     resource: File.filePlus),
        UIIconEntry(id: "file-text", name: "file-text", category: "File",
                     resource: File.fileText),
        UIIconEntry(id: "folder", name: "folder", category: "File",
                     resource: File.folder),
        UIIconEntry(id: "folder-open", name: "folder-open", category: "File",
                     resource: File.folderOpen),
        UIIconEntry(id: "folder-plus", name: "folder-plus", category: "File",
                     resource: File.folderPlus),
        UIIconEntry(id: "inbox", name: "inbox", category: "File",
                     resource: File.inbox),
        UIIconEntry(id: "package", name: "package", category: "File",
                     resource: File.package),
        UIIconEntry(id: "save", name: "save", category: "File",
                     resource: File.save),
        UIIconEntry(id: "box", name: "box", category: "Editor",
                     resource: Editor.box),
        UIIconEntry(id: "brackets", name: "brackets", category: "Editor",
                     resource: Editor.brackets),
        UIIconEntry(id: "brush", name: "brush", category: "Editor",
                     resource: Editor.brush),
        UIIconEntry(id: "bug", name: "bug", category: "Editor",
                     resource: Editor.bug),
        UIIconEntry(id: "code", name: "code", category: "Editor",
                     resource: Editor.code),
        UIIconEntry(id: "compass", name: "compass", category: "Editor",
                     resource: Editor.compass),
        UIIconEntry(id: "eraser", name: "eraser", category: "Editor",
                     resource: Editor.eraser),
        UIIconEntry(id: "gamepad", name: "gamepad", category: "Editor",
                     resource: Editor.gamepad),
        UIIconEntry(id: "git-branch", name: "git-branch", category: "Editor",
                     resource: Editor.gitBranch),
        UIIconEntry(id: "git-commit", name: "git-commit", category: "Editor",
                     resource: Editor.gitCommit),
        UIIconEntry(id: "git-merge", name: "git-merge", category: "Editor",
                     resource: Editor.gitMerge),
        UIIconEntry(id: "hammer", name: "hammer", category: "Editor",
                     resource: Editor.hammer),
        UIIconEntry(id: "layers", name: "layers", category: "Editor",
                     resource: Editor.layers),
        UIIconEntry(id: "lightbulb", name: "lightbulb", category: "Editor",
                     resource: Editor.lightbulb),
        UIIconEntry(id: "map-pin", name: "map-pin", category: "Editor",
                     resource: Editor.mapPin),
        UIIconEntry(id: "pause", name: "pause", category: "Editor",
                     resource: Editor.pause),
        UIIconEntry(id: "play", name: "play", category: "Editor",
                     resource: Editor.play),
        UIIconEntry(id: "repeat", name: "repeat", category: "Editor",
                     resource: Editor.`repeat`),
        UIIconEntry(id: "shuffle", name: "shuffle", category: "Editor",
                     resource: Editor.shuffle),
        UIIconEntry(id: "skip-back", name: "skip-back", category: "Editor",
                     resource: Editor.skipBack),
        UIIconEntry(id: "skip-forward", name: "skip-forward", category: "Editor",
                     resource: Editor.skipForward),
        UIIconEntry(id: "stop", name: "stop", category: "Editor",
                     resource: Editor.stop),
        UIIconEntry(id: "terminal", name: "terminal", category: "Editor",
                     resource: Editor.terminal),
        UIIconEntry(id: "wrench", name: "wrench", category: "Editor",
                     resource: Editor.wrench),
        UIIconEntry(id: "columns-2", name: "columns-2", category: "Layout",
                     resource: Layout.columns2),
        UIIconEntry(id: "columns-3", name: "columns-3", category: "Layout",
                     resource: Layout.columns3),
        UIIconEntry(id: "dashboard", name: "dashboard", category: "Layout",
                     resource: Layout.dashboard),
        UIIconEntry(id: "grid", name: "grid", category: "Layout",
                     resource: Layout.grid),
        UIIconEntry(id: "indent", name: "indent", category: "Layout",
                     resource: Layout.indent),
        UIIconEntry(id: "outdent", name: "outdent", category: "Layout",
                     resource: Layout.outdent),
        UIIconEntry(id: "panel-bottom", name: "panel-bottom", category: "Layout",
                     resource: Layout.panelBottom),
        UIIconEntry(id: "panel-left", name: "panel-left", category: "Layout",
                     resource: Layout.panelLeft),
        UIIconEntry(id: "panel-right", name: "panel-right", category: "Layout",
                     resource: Layout.panelRight),
        UIIconEntry(id: "panel-top", name: "panel-top", category: "Layout",
                     resource: Layout.panelTop),
        UIIconEntry(id: "rows-2", name: "rows-2", category: "Layout",
                     resource: Layout.rows2),
        UIIconEntry(id: "rows-3", name: "rows-3", category: "Layout",
                     resource: Layout.rows3),
        UIIconEntry(id: "sidebar", name: "sidebar", category: "Layout",
                     resource: Layout.sidebar),
        UIIconEntry(id: "table", name: "table", category: "Layout",
                     resource: Layout.table),
        UIIconEntry(id: "activity", name: "activity", category: "Data",
                     resource: Data.activity),
        UIIconEntry(id: "calendar", name: "calendar", category: "Data",
                     resource: Data.calendar),
        UIIconEntry(id: "chart-bar", name: "chart-bar", category: "Data",
                     resource: Data.chartBar),
        UIIconEntry(id: "chart-line", name: "chart-line", category: "Data",
                     resource: Data.chartLine),
        UIIconEntry(id: "chart-pie", name: "chart-pie", category: "Data",
                     resource: Data.chartPie),
        UIIconEntry(id: "clock", name: "clock", category: "Data",
                     resource: Data.clock),
        UIIconEntry(id: "hourglass", name: "hourglass", category: "Data",
                     resource: Data.hourglass),
        UIIconEntry(id: "timer", name: "timer", category: "Data",
                     resource: Data.timer),
        UIIconEntry(id: "trending-down", name: "trending-down", category: "Data",
                     resource: Data.trendingDown),
        UIIconEntry(id: "trending-up", name: "trending-up", category: "Data",
                     resource: Data.trendingUp),
        UIIconEntry(id: "camera", name: "camera", category: "Media",
                     resource: Media.camera),
        UIIconEntry(id: "image", name: "image", category: "Media",
                     resource: Media.image),
        UIIconEntry(id: "mic", name: "mic", category: "Media",
                     resource: Media.mic),
        UIIconEntry(id: "monitor", name: "monitor", category: "Media",
                     resource: Media.monitor),
        UIIconEntry(id: "music", name: "music", category: "Media",
                     resource: Media.music),
        UIIconEntry(id: "video", name: "video", category: "Media",
                     resource: Media.video),
        UIIconEntry(id: "volume", name: "volume", category: "Media",
                     resource: Media.volume),
        UIIconEntry(id: "volume-x", name: "volume-x", category: "Media",
                     resource: Media.volumeX),
        UIIconEntry(id: "battery", name: "battery", category: "Device",
                     resource: Device.battery),
        UIIconEntry(id: "bluetooth", name: "bluetooth", category: "Device",
                     resource: Device.bluetooth),
        UIIconEntry(id: "cloud", name: "cloud", category: "Device",
                     resource: Device.cloud),
        UIIconEntry(id: "cloud-download", name: "cloud-download", category: "Device",
                     resource: Device.cloudDownload),
        UIIconEntry(id: "cloud-upload", name: "cloud-upload", category: "Device",
                     resource: Device.cloudUpload),
        UIIconEntry(id: "cpu", name: "cpu", category: "Device",
                     resource: Device.cpu),
        UIIconEntry(id: "database", name: "database", category: "Device",
                     resource: Device.database),
        UIIconEntry(id: "hard-drive", name: "hard-drive", category: "Device",
                     resource: Device.hardDrive),
        UIIconEntry(id: "moon", name: "moon", category: "Device",
                     resource: Device.moon),
        UIIconEntry(id: "server", name: "server", category: "Device",
                     resource: Device.server),
        UIIconEntry(id: "sun", name: "sun", category: "Device",
                     resource: Device.sun),
        UIIconEntry(id: "wifi", name: "wifi", category: "Device",
                     resource: Device.wifi),
        UIIconEntry(id: "circle-user", name: "circle-user", category: "User",
                     resource: User.circleUser),
        UIIconEntry(id: "user", name: "user", category: "User",
                     resource: User.user),
        UIIconEntry(id: "user-plus", name: "user-plus", category: "User",
                     resource: User.userPlus),
        UIIconEntry(id: "users", name: "users", category: "User",
                     resource: User.users),
        UIIconEntry(id: "align-center", name: "align-center", category: "Text",
                     resource: Text.alignCenter),
        UIIconEntry(id: "align-left", name: "align-left", category: "Text",
                     resource: Text.alignLeft),
        UIIconEntry(id: "align-right", name: "align-right", category: "Text",
                     resource: Text.alignRight),
        UIIconEntry(id: "bold", name: "bold", category: "Text",
                     resource: Text.bold),
        UIIconEntry(id: "heading", name: "heading", category: "Text",
                     resource: Text.heading),
        UIIconEntry(id: "italic", name: "italic", category: "Text",
                     resource: Text.italic),
        UIIconEntry(id: "list", name: "list", category: "Text",
                     resource: Text.list),
        UIIconEntry(id: "list-ordered", name: "list-ordered", category: "Text",
                     resource: Text.listOrdered),
        UIIconEntry(id: "pilcrow", name: "pilcrow", category: "Text",
                     resource: Text.pilcrow),
        UIIconEntry(id: "type", name: "type", category: "Text",
                     resource: Text.`type`),
        UIIconEntry(id: "underline", name: "underline", category: "Text",
                     resource: Text.underline),
        UIIconEntry(id: "wrap-text", name: "wrap-text", category: "Text",
                     resource: Text.wrapText),
        UIIconEntry(id: "at-sign", name: "at-sign", category: "Shape",
                     resource: Shape.atSign),
        UIIconEntry(id: "book-open", name: "book-open", category: "Shape",
                     resource: Shape.bookOpen),
        UIIconEntry(id: "circle", name: "circle", category: "Shape",
                     resource: Shape.circle),
        UIIconEntry(id: "circle-dot", name: "circle-dot", category: "Shape",
                     resource: Shape.circleDot),
        UIIconEntry(id: "circle-minus", name: "circle-minus", category: "Shape",
                     resource: Shape.circleMinus),
        UIIconEntry(id: "circle-plus", name: "circle-plus", category: "Shape",
                     resource: Shape.circlePlus),
        UIIconEntry(id: "dot", name: "dot", category: "Shape",
                     resource: Shape.dot),
        UIIconEntry(id: "globe", name: "globe", category: "Shape",
                     resource: Shape.globe),
        UIIconEntry(id: "hash", name: "hash", category: "Shape",
                     resource: Shape.hash),
        UIIconEntry(id: "home", name: "home", category: "Shape",
                     resource: Shape.home),
        UIIconEntry(id: "key", name: "key", category: "Shape",
                     resource: Shape.key),
        UIIconEntry(id: "log-in", name: "log-in", category: "Shape",
                     resource: Shape.logIn),
        UIIconEntry(id: "log-out", name: "log-out", category: "Shape",
                     resource: Shape.logOut),
        UIIconEntry(id: "mail", name: "mail", category: "Shape",
                     resource: Shape.mail),
        UIIconEntry(id: "message-circle", name: "message-circle", category: "Shape",
                     resource: Shape.messageCircle),
        UIIconEntry(id: "message-square", name: "message-square", category: "Shape",
                     resource: Shape.messageSquare),
        UIIconEntry(id: "paperclip", name: "paperclip", category: "Shape",
                     resource: Shape.paperclip),
        UIIconEntry(id: "pin", name: "pin", category: "Shape",
                     resource: Shape.pin),
        UIIconEntry(id: "pin-off", name: "pin-off", category: "Shape",
                     resource: Shape.pinOff),
        UIIconEntry(id: "send", name: "send", category: "Shape",
                     resource: Shape.send),
        UIIconEntry(id: "square", name: "square", category: "Shape",
                     resource: Shape.square),
        UIIconEntry(id: "square-check", name: "square-check", category: "Shape",
                     resource: Shape.squareCheck),
        UIIconEntry(id: "tag", name: "tag", category: "Shape",
                     resource: Shape.tag),
        UIIconEntry(id: "triangle", name: "triangle", category: "Shape",
                     resource: Shape.triangle),
    ]

    /// Case-insensitive search across icon name and category.
    static func search(_ query: String) -> [UIIconEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return all }
        return all.filter { entry in
            let text = entry.name + " " + entry.category
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    static var categories: [String] {
        all.reduce(into: []) { result, entry in
            if !result.contains(entry.category) { result.append(entry.category) }
        }
    }
}

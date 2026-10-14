import GuavaUI
import GalleryContent

let arguments = CommandLine.arguments
let page = arguments.firstIndex(of: "--component").flatMap {
    arguments.indices.contains($0 + 1) ? GalleryCatalog.page(named: arguments[$0 + 1]) : nil
} ?? .introduction
try Application.run(config: ApplicationConfiguration(title: "GuavaUI — Component Showcase")) {
    GalleryView(initialPage: page)
}

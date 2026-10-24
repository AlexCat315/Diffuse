// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "StudioDocuments",
    platforms: [.macOS(.v26), .iOS(.v26)], products: [.library(name: "StudioDocuments", targets: ["StudioDocuments"])],
    targets: [.target(name: "StudioDocuments"), .testTarget(name: "StudioDocumentsTests", dependencies: ["StudioDocuments"])])

// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "StudioDocuments", products: [.library(name: "StudioDocuments", targets: ["StudioDocuments"])],
    targets: [.target(name: "StudioDocuments"), .testTarget(name: "StudioDocumentsTests", dependencies: ["StudioDocuments"])])

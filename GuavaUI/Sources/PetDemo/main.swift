//
//  main.swift
//  PetDemo
//
//  Software Pet demo — a 2D sprite pet that stands / sits on components and
//  jumps between buttons. Click a button: the pet launches off its current
//  perch along a ballistic arc and lands seated on that button.
//

import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUICore

// MARK: - Locate packaged sprite frames

func resolvePetResourcePath(_ name: String) -> String {
    let fm = FileManager.default
    let fileName = "\(name).png"

    if let url = Bundle.main.url(forResource: name, withExtension: "png") {
        return url.path
    }

    var bundles: [Bundle] = [Bundle.main]
    var searchRoots: [URL] = [Bundle.main.bundleURL]
    if let resourceURL = Bundle.main.resourceURL { searchRoots.append(resourceURL) }
    searchRoots.append(Bundle.main.bundleURL.deletingLastPathComponent())

    for root in searchRoots {
        guard let urls = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil) else { continue }
        for bundleURL in urls where bundleURL.pathExtension == "bundle" {
            if let bundle = Bundle(url: bundleURL) { bundles.append(bundle) }
        }
    }

    for bundle in bundles {
        if let url = bundle.url(forResource: name, withExtension: "png") {
            return url.path
        }
        let base = bundle.resourceURL ?? bundle.bundleURL
        if let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == fileName {
                return url.path
            }
        }
    }
    return ""
}

// MARK: - Build the sprite sheet

var frames: [PetPose: String] = [:]
for pose in PetPose.allCases {
    let path = resolvePetResourcePath(pose.rawValue)
    if !path.isEmpty { frames[pose] = path }
}

let sheet = PetSpriteSheet(displaySize: 124, frames: frames)
let world = PetWorld(spriteSheet: sheet, initialAnchorID: "home", perchPose: .idle)

// MARK: - Scene

struct PetDemoRoot: View {
    let world: PetWorld

    var body: some View {
        Column(alignment: .center, spacing: 0) {
            Text("Software Pet")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(Color(r: 0.93, g: 0.90, b: 0.99))

            Text("点击下方任一按钮，宠物会沿抛物线跳到该按钮上坐下")
                .font(.system(size: 14))
                .foregroundColor(Color(r: 0.66, g: 0.64, b: 0.74))
                .padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))

            Row(alignment: .center, spacing: 12) {
                Button("随机游走") { world.wander() }
                Button("站 / 坐") { world.toggleRest() }
            }
            .padding(EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0))

            Spacer()

            Row(alignment: .bottom, spacing: 0) {
                Button("首页") { world.go(to: "home") }
                    .petAnchor("home")
                Spacer()
                Button("设置") { world.go(to: "settings") }
                    .petAnchor("settings")
                Spacer()
                Button("关于") { world.go(to: "about") }
                    .petAnchor("about")
            }
            .frame(width: .points(560))

            Spacer()
        }
        .framePercent(width: 100, height: 100)
        .padding(28)
        .background(Color(r: 0.10, g: 0.09, b: 0.14))
    }
}

// MARK: - Run

try AppRuntime.run(config: AppConfig(title: "GuavaUI · Software Pet")) {
    PetScene(world: world) {
        PetDemoRoot(world: world)
    }
}

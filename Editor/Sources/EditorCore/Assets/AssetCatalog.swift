import Foundation
import GuavaUICompose
import simd

/// 编辑器内置的资产种类。每种映射到一组默认组件。
public enum EditorAssetKind: String, Codable, Sendable, CaseIterable {
    case cube
    case sphere
    case plane
    case pointLight
    case directionalLight
    case camera
    case empty

    public var displayLabel: String {
        switch self {
        case .cube: return "Cube"
        case .sphere: return "Sphere"
        case .plane: return "Plane"
        case .pointLight: return "Point Light"
        case .directionalLight: return "Directional Light"
        case .camera: return "Camera"
        case .empty: return "Empty"
        }
    }

    public var sceneKindLabel: String {
        switch self {
        case .cube, .sphere, .plane: return "Static Mesh"
        case .pointLight: return "Point Light"
        case .directionalLight: return "Directional Light"
        case .camera: return "Camera"
        case .empty: return "Empty"
        }
    }
}

public struct EditorAsset: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: EditorAssetKind

    public init(id: String, name: String, kind: EditorAssetKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public func dragPayload() -> EditorAssetDragPayload {
        EditorAssetDragPayload(assetID: id,
                               displayName: name,
                               kindLabel: kind.sceneKindLabel)
    }
}

public enum EditorAssetCatalog {
    public static let defaultEntries: [EditorAsset] = [
        .init(id: "primitive.cube", name: "Cube", kind: .cube),
        .init(id: "primitive.sphere", name: "Sphere", kind: .sphere),
        .init(id: "primitive.plane", name: "Plane", kind: .plane),
        .init(id: "light.point", name: "Point Light", kind: .pointLight),
        .init(id: "light.directional", name: "Directional Light", kind: .directionalLight),
        .init(id: "camera.perspective", name: "Camera", kind: .camera),
        .init(id: "node.empty", name: "Empty", kind: .empty),
    ]

    public static func asset(for id: String) -> EditorAsset? {
        defaultEntries.first { $0.id == id }
    }
}

/// 进程内的视口落点矩形。AssetBrowser 行在指针抬起时通过它判断
/// 当前光标是否落在视口内。值由 ViewportPanel 在每一帧通过
/// `ViewportHost.onScreenFrameChange` 更新，不处于多线程读写环境。
public enum EditorViewportDropTarget {
    nonisolated(unsafe) public static var frame: ViewportScreenFrame?
}

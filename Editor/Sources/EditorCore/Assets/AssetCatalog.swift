import AssetPipeline
import Foundation
import GuavaUICompose
import simd

public struct EditorAsset: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let absolutePath: String
    public let kind: ImportableAssetKind
    public let meshIndex: Int

    public init(id: String,
                name: String,
                relativePath: String,
                absolutePath: String,
                kind: ImportableAssetKind,
                meshIndex: Int) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.meshIndex = meshIndex
    }

    public func dragPayload() -> EditorAssetDragPayload {
        EditorAssetDragPayload(assetID: id,
                               displayName: name,
                               kindLabel: kind.sceneKindLabel)
    }
}

public enum EditorAssetCatalog {
    @discardableResult
    public static func loadProject(at rootPath: String) throws -> [EditorAsset] {
        try AssetRegistry.shared.loadProject(at: rootPath).map(makeAsset)
    }

    public static func entries() -> [EditorAsset] {
        AssetRegistry.shared.entriesSnapshot().map(makeAsset)
    }

    public static func asset(for id: String) -> EditorAsset? {
        AssetRegistry.shared.entry(for: id).map(makeAsset)
    }

    private static func makeAsset(_ entry: AssetRegistryEntry) -> EditorAsset {
        EditorAsset(id: entry.id,
                    name: entry.name,
                    relativePath: entry.relativePath,
                    absolutePath: entry.absolutePath,
                    kind: entry.kind,
                    meshIndex: entry.meshIndex)
    }
}

/// 进程内的视口落点矩形。AssetBrowser 行在指针抬起时通过它判断
/// 当前光标是否落在视口内。值由 ViewportPanel 在每一帧通过
/// `ViewportHost.onScreenFrameChange` 更新，不处于多线程读写环境。
public enum EditorViewportDropTarget {
    nonisolated(unsafe) public static var frame: ViewportScreenFrame?
}

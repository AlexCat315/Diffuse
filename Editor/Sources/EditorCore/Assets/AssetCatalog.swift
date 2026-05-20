import AssetPipeline
import Foundation
import GuavaUICompose
import SIMDCompat

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

/// 杩涚▼鍐呯殑瑙嗗彛钀界偣鐭╁舰銆侫ssetBrowser 琛屽湪鎸囬拡鎶捣鏃堕€氳繃瀹冨垽鏂?
/// 褰撳墠鍏夋爣鏄惁钀藉湪瑙嗗彛鍐呫€傚€肩敱 ViewportPanel 鍦ㄦ瘡涓€甯ч€氳繃
/// `ViewportHost.onScreenFrameChange` 鏇存柊锛屼笉澶勪簬澶氱嚎绋嬭鍐欑幆澧冦€?
public enum EditorViewportDropTarget {
    nonisolated(unsafe) public static var frame: ViewportScreenFrame?
}

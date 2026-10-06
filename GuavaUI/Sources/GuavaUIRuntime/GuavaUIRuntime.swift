/// GuavaUI Runtime — 占位模块
///
/// 职责：平台层、布局引擎、文字渲染、节点树、recompose 运行时。
/// 详细设计见 docs/guava-ui-blueprint.md。
@_exported import Foundation
@_exported import GuavaUICore

// Preserve the desktop API while using the same implementations on Wasm.
public typealias Color = GuavaUICore.Color
public typealias UIVertex = GuavaUICore.UIVertex
public typealias UIRect = GuavaUICore.UIRect
public typealias DrawList = GuavaUICore.DrawList
public typealias DrawBatch = GuavaUICore.DrawBatch
public typealias TextureID = GuavaUICore.TextureID
public typealias State<Value> = GuavaUICore.State<Value>
public typealias Binding<Value> = GuavaUICore.Binding<Value>
public typealias DynamicProperty = GuavaUICore.DynamicProperty
typealias UIShader = GuavaUICore.UIShader

public enum GuavaUIRuntime {
    public static let version = "0.1.0-wip"
}

internal import GuavaUI
internal import GuavaUIRuntime

enum ScriptSymbolIcon: Equatable {
    case type, interface, function, property, enumeration, variable, namespace, value, symbol

    init(kind: Int) {
        switch kind {
        case 5, 23: self = .type
        case 11: self = .interface
        case 6, 9, 12: self = .function
        case 7, 8: self = .property
        case 10, 22: self = .enumeration
        case 13, 14: self = .variable
        case 2, 3, 4: self = .namespace
        case 15...21, 24...26: self = .value
        default: self = .symbol
        }
    }

    var resource: BundleImageResource {
        switch self {
        case .type: UIIcons.Editor.box
        case .interface: UIIcons.Editor.gitMerge
        case .function: UIIcons.Editor.code
        case .property: UIIcons.Action.sliders
        case .enumeration: UIIcons.Text.list
        case .variable: UIIcons.Shape.hash
        case .namespace: UIIcons.File.package
        case .value: UIIcons.Text.type
        case .symbol: UIIcons.File.fileCode
        }
    }
}

/// Label placement shared by forms and property grids. Adaptive placement uses
/// the field's own allocated width, rather than the host window's width class.
public enum FieldLabelPlacement: Sendable, Equatable {
    case adaptive
    case leading
    case stacked

    func isLeading(width: Float, labelWidth: Float, minValueWidth: Float, spacing: Float) -> Bool {
        switch self {
        case .adaptive: width >= labelWidth + spacing + minValueWidth
        case .leading: true
        case .stacked: false
        }
    }
}

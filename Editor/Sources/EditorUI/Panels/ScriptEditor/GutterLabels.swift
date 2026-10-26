import Foundation
import CoveUI

func scriptGutterLabels() -> TextGutterLabels {
    var labels = TextGutterLabels()
    labels.lineActions = { String(format: L("Line %d actions"), $0 + 1) }
    labels.addBreakpoint = { String(format: L("Add breakpoint at line %d"), $0 + 1) }
    labels.removeBreakpoint = { String(format: L("Remove breakpoint at line %d"), $0 + 1) }
    labels.enableBreakpoint = { String(format: L("Enable breakpoint at line %d"), $0 + 1) }
    labels.disableBreakpoint = { String(format: L("Disable breakpoint at line %d"), $0 + 1) }
    labels.execution = { String(format: L("Execution paused at line %d"), $0 + 1) }
    labels.breakpointState = {
        switch $0 { case .enabled: L("Enabled breakpoint"); case .disabled: L("Disabled breakpoint"); case .unverified: L("Unverified breakpoint") }
    }
    return labels
}

func scriptFoldingLabels() -> TextFoldingLabels {
    var labels = TextFoldingLabels()
    labels.collapse = { String(format: L("Collapse code at line %d"), $0 + 1) }
    labels.expand = { String(format: L("Expand code at line %d"), $0 + 1) }
    labels.summary = { String(format: L("%d folded lines"), $0) }
    labels.hiddenBreakpoints = { String(format: L("%d breakpoints in folded code"), $0) }
    return labels
}

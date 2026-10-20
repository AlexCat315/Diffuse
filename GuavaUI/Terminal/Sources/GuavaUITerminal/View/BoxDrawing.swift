internal import GuavaUIRuntime

/// Draws box-drawing (U+2500–257F), block elements (U+2580–259F) and the
/// Powerline separators (U+E0B0–E0B3) as geometry instead of font glyphs, so
/// lines meet exactly at cell edges whatever font (or fallback) is in use.
enum BoxDrawing {
    static func handles(_ scalar: UInt32) -> Bool {
        (0x2500...0x259F).contains(scalar) || (0xE0B0...0xE0B3).contains(scalar)
    }

    static func draw(_ scalar: UInt32, in cell: UIRect, color: Color, into list: DrawList) {
        var painter = Painter(cell: cell, color: color, list: list)
        switch scalar {
        case 0x2580...0x259F: painter.block(scalar)
        case 0xE0B0...0xE0B3: painter.powerline(scalar)
        case 0x2504...0x250B, 0x254C...0x254F: painter.dashes(scalar)
        case 0x256D...0x2570: painter.arc(scalar)
        case 0x2571...0x2573: painter.diagonal(scalar)
        default:
            guard let arms = arms(scalar) else { return }
            painter.lines(arms)
        }
    }

    /// Line weight per arm, in (up, right, down, left) order:
    /// 0 none, 1 light, 2 heavy, 3 double.
    struct Arms: Equatable {
        var up: Int, right: Int, down: Int, left: Int
    }

    /// Four digits per character from U+2500 (`-` marks shapes drawn elsewhere).
    private static let table: [String] = [
        "0101", "0202", "1010", "2020", "-", "-", "-", "-", "-", "-", "-", "-",  // 2500–250B
        "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022",           // 250C–2513
        "1100", "1200", "2100", "2200", "1001", "1002", "2001", "2002",           // 2514–251B
        "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",           // 251C–2523
        "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022",           // 2524–252B
        "0111", "0112", "0211", "0212", "0121", "0122", "0221", "0222",           // 252C–2533
        "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",           // 2534–253B
        "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112",           // 253C–2543
        "2211", "1122", "1221", "2212", "1222", "2122", "2221", "2222",           // 2544–254B
        "-", "-", "-", "-",                                                       // 254C–254F
        "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033",           // 2550–2557
        "1300", "3100", "3300", "1003", "3001", "3003", "1310", "3130",           // 2558–255F
        "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303",           // 2560–2567
        "3101", "3303", "1313", "3131", "3333",                                   // 2568–256C
        "-", "-", "-", "-", "-", "-", "-",                                        // 256D–2573
        "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020",           // 2574–257B
        "0201", "1020", "0102", "2010",                                           // 257C–257F
    ]

    static func arms(_ scalar: UInt32) -> Arms? {
        guard (0x2500...0x257F).contains(scalar) else { return nil }
        let entry = Array(table[Int(scalar - 0x2500)])
        guard entry.count == 4 else { return nil }
        let digits = entry.compactMap(\.wholeNumberValue)
        return Arms(up: digits[0], right: digits[1], down: digits[2], left: digits[3])
    }

    private struct Painter {
        let cell: UIRect
        let color: Color
        let list: DrawList
        let light: Float
        let heavy: Float
        /// Half the distance between the two strokes of a double line.
        let gap: Float
        let centerX: Float
        let centerY: Float

        init(cell: UIRect, color: Color, list: DrawList) {
            self.cell = cell
            self.color = color
            self.list = list
            light = max(1, (cell.height / 16).rounded())
            heavy = light * 2
            gap = light
            centerX = (cell.x + cell.width / 2).rounded(.down)
            centerY = (cell.y + cell.height / 2).rounded(.down)
        }

        private func weight(_ arm: Int) -> Float { arm == 2 ? heavy : light }

        private func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
            guard x1 > x0, y1 > y0 else { return }
            list.addRect(UIRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), color: color)
        }

        func lines(_ arms: Arms) {
            let top = cell.y, bottom = cell.y + cell.height, left = cell.x, right = cell.x + cell.width
            // Single strokes reach past the centre by half the widest crossing
            // stroke, so corners and tees close without notches.
            let horizontalReach = max(arms.left == 3 || arms.right == 3 ? gap + light / 2 : 0,
                                      arms.left == 2 || arms.right == 2 ? heavy / 2 : light / 2)
            let verticalReach = max(arms.up == 3 || arms.down == 3 ? gap + light / 2 : 0,
                                    arms.up == 2 || arms.down == 2 ? heavy / 2 : light / 2)
            // A double stroke ends on the near (inner) side when a line turns
            // towards it and runs to the far (outer) side otherwise; that is
            // what makes ╔ ╠ ╬ read as two parallel lines.
            func join(_ turns: Bool, near: Float, far: Float) -> Float { turns ? near : far }

            if arms.up == 3 {
                vertical(centerX - gap, top, join(arms.left != 0, near: centerY - gap, far: centerY + gap))
                vertical(centerX + gap, top, join(arms.right != 0, near: centerY - gap, far: centerY + gap))
            } else if arms.up > 0 {
                rect(centerX - weight(arms.up) / 2, top, centerX + weight(arms.up) / 2, centerY + horizontalReach)
            }
            if arms.down == 3 {
                vertical(centerX - gap, join(arms.left != 0, near: centerY + gap, far: centerY - gap), bottom)
                vertical(centerX + gap, join(arms.right != 0, near: centerY + gap, far: centerY - gap), bottom)
            } else if arms.down > 0 {
                rect(centerX - weight(arms.down) / 2, centerY - horizontalReach, centerX + weight(arms.down) / 2, bottom)
            }
            if arms.left == 3 {
                horizontal(centerY - gap, left, join(arms.up != 0, near: centerX - gap, far: centerX + gap))
                horizontal(centerY + gap, left, join(arms.down != 0, near: centerX - gap, far: centerX + gap))
            } else if arms.left > 0 {
                rect(left, centerY - weight(arms.left) / 2, centerX + verticalReach, centerY + weight(arms.left) / 2)
            }
            if arms.right == 3 {
                horizontal(centerY - gap, join(arms.up != 0, near: centerX + gap, far: centerX - gap), right)
                horizontal(centerY + gap, join(arms.down != 0, near: centerX + gap, far: centerX - gap), right)
            } else if arms.right > 0 {
                rect(centerX - verticalReach, centerY - weight(arms.right) / 2, right, centerY + weight(arms.right) / 2)
            }
        }

        /// One stroke of a double line, centred on `x` (or `y`).
        private func vertical(_ x: Float, _ y0: Float, _ y1: Float) {
            rect(x - light / 2, min(y0, y1) - light / 2, x + light / 2, max(y0, y1) + light / 2)
        }

        private func horizontal(_ y: Float, _ x0: Float, _ x1: Float) {
            rect(min(x0, x1) - light / 2, y - light / 2, max(x0, x1) + light / 2, y + light / 2)
        }

        func dashes(_ scalar: UInt32) {
            let (count, isHeavy, isVertical): (Int, Bool, Bool) = switch scalar {
            case 0x2504: (3, false, false)
            case 0x2505: (3, true, false)
            case 0x2506: (3, false, true)
            case 0x2507: (3, true, true)
            case 0x2508: (4, false, false)
            case 0x2509: (4, true, false)
            case 0x250A: (4, false, true)
            case 0x250B: (4, true, true)
            case 0x254C: (2, false, false)
            case 0x254D: (2, true, false)
            case 0x254E: (2, false, true)
            default: (2, true, true)
            }
            let w = isHeavy ? heavy : light
            let length = isVertical ? cell.height : cell.width
            let step = length / Float(count)
            let dash = (step * 0.6).rounded(.up)
            for index in 0..<count {
                let start = (isVertical ? cell.y : cell.x) + Float(index) * step + (step - dash) / 2
                if isVertical { rect(centerX - w / 2, start, centerX + w / 2, start + dash) }
                else { rect(start, centerY - w / 2, start + dash, centerY + w / 2) }
            }
        }

        /// Rounded corners: a quarter circle joining the two arms.
        func arc(_ scalar: UInt32) {
            let radius = min(cell.width, cell.height) / 2
            // Direction of the vertical (dy) and horizontal (dx) arms.
            let (dy, dx): (Float, Float) = switch scalar {
            case 0x256D: (1, 1)    // ╭ down and right
            case 0x256E: (1, -1)   // ╮ down and left
            case 0x256F: (-1, -1)  // ╯ up and left
            default: (-1, 1)       // ╰ up and right
            }
            let arcCenterX = centerX + dx * radius, arcCenterY = centerY + dy * radius
            let segments = 8
            var previous = (x: centerX, y: centerY + dy * radius)
            for step in 1...segments {
                let angle = Float(step) / Float(segments) * Float.pi / 2
                let point = (x: arcCenterX - dx * radius * cos(angle), y: arcCenterY - dy * radius * sin(angle))
                list.addLine(fromX: previous.x, fromY: previous.y, toX: point.x, toY: point.y, thickness: light, color: color)
                previous = point
            }
            if dy > 0 { rect(centerX - light / 2, centerY + radius, centerX + light / 2, cell.y + cell.height) }
            else { rect(centerX - light / 2, cell.y, centerX + light / 2, centerY - radius) }
            if dx > 0 { rect(centerX + radius, centerY - light / 2, cell.x + cell.width, centerY + light / 2) }
            else { rect(cell.x, centerY - light / 2, centerX - radius, centerY + light / 2) }
        }

        func diagonal(_ scalar: UInt32) {
            let left = cell.x, right = cell.x + cell.width, top = cell.y, bottom = cell.y + cell.height
            if scalar != 0x2572 { list.addLine(fromX: right, fromY: top, toX: left, toY: bottom, thickness: light, color: color) }
            if scalar != 0x2571 { list.addLine(fromX: left, fromY: top, toX: right, toY: bottom, thickness: light, color: color) }
        }

        func block(_ scalar: UInt32) {
            let x = cell.x, y = cell.y, w = cell.width, h = cell.height
            func fill(_ fx: Float, _ fy: Float, _ fw: Float, _ fh: Float, alpha: Float = 1) {
                list.addRect(UIRect(x: x + fx * w, y: y + fy * h, width: fw * w, height: fh * h),
                             color: color.multipliedAlpha(alpha))
            }
            switch scalar {
            case 0x2580: fill(0, 0, 1, 0.5)
            case 0x2581...0x2588:
                let eighths = Float(scalar - 0x2580) / 8
                fill(0, 1 - eighths, 1, eighths)
            case 0x2589...0x258F:
                let eighths = Float(0x2590 - scalar) / 8
                fill(0, 0, eighths, 1)
            case 0x2590: fill(0.5, 0, 0.5, 1)
            case 0x2591: fill(0, 0, 1, 1, alpha: 0.25)
            case 0x2592: fill(0, 0, 1, 1, alpha: 0.5)
            case 0x2593: fill(0, 0, 1, 1, alpha: 0.75)
            case 0x2594: fill(0, 0, 1, 0.125)
            case 0x2595: fill(0.875, 0, 0.125, 1)
            default:
                // Quadrants ▖▗▘▙▚▛▜▝▞▟ as bits: upper-left, upper-right, lower-left, lower-right.
                let quadrants: [UInt32: (Bool, Bool, Bool, Bool)] = [
                    0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                    0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                    0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                    0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                    0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
                ]
                guard let q = quadrants[scalar] else { return }
                if q.0 { fill(0, 0, 0.5, 0.5) }
                if q.1 { fill(0.5, 0, 0.5, 0.5) }
                if q.2 { fill(0, 0.5, 0.5, 0.5) }
                if q.3 { fill(0.5, 0.5, 0.5, 0.5) }
            }
        }

        func powerline(_ scalar: UInt32) {
            let left = cell.x, right = cell.x + cell.width, top = cell.y, bottom = cell.y + cell.height
            let middle = cell.y + cell.height / 2
            switch scalar {
            case 0xE0B0: list.addTriangle(left, top, right, middle, left, bottom, color: color)
            case 0xE0B2: list.addTriangle(right, top, left, middle, right, bottom, color: color)
            case 0xE0B1:
                list.addLine(fromX: left, fromY: top, toX: right, toY: middle, thickness: light, color: color)
                list.addLine(fromX: right, fromY: middle, toX: left, toY: bottom, thickness: light, color: color)
            default:
                list.addLine(fromX: right, fromY: top, toX: left, toY: middle, thickness: light, color: color)
                list.addLine(fromX: left, fromY: middle, toX: right, toY: bottom, thickness: light, color: color)
            }
        }
    }
}

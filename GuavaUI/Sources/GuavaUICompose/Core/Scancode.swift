/// SDL/USB-HID keyboard scancodes shared by compose controls. One named
/// constant per key the components handle — no scattered magic numbers.
public enum Scancode {
    public static let a: UInt32 = 4
    public static let b: UInt32 = 5
    public static let c: UInt32 = 6
    public static let d: UInt32 = 7
    public static let e: UInt32 = 8
    public static let f: UInt32 = 9
    public static let k: UInt32 = 14
    public static let l: UInt32 = 15
    public static let n: UInt32 = 17
    public static let o: UInt32 = 18
    public static let q: UInt32 = 20
    public static let r: UInt32 = 21
    public static let s: UInt32 = 22
    public static let t: UInt32 = 23
    public static let v: UInt32 = 25
    public static let w: UInt32 = 26
    public static let x: UInt32 = 27
    public static let z: UInt32 = 29
    public static let digit0: UInt32 = 39
    public static let digit1: UInt32 = 30
    public static let digit2: UInt32 = 31
    public static let digit3: UInt32 = 32
    public static let comma: UInt32 = 54
    public static let `return`: UInt32 = 40
    public static let escape: UInt32 = 41
    public static let backspace: UInt32 = 42
    public static let space: UInt32 = 44
    public static let home: UInt32 = 74
    public static let delete: UInt32 = 76
    public static let end: UInt32 = 77
    public static let arrowRight: UInt32 = 79
    public static let arrowLeft: UInt32 = 80
    public static let arrowDown: UInt32 = 81
    public static let arrowUp: UInt32 = 82
    public static let keypadEnter: UInt32 = 88
    public static let f2: UInt32 = 59
}

/// Unambiguous spelling for clients that also import an engine/runtime module
/// exposing its own SDL scancode namespace.
public typealias ComposeScancode = Scancode

/// SDL/USB-HID keyboard scancodes shared by compose controls. One named
/// constant per key the components handle — no scattered magic numbers.
public enum Scancode {
    public static let a: UInt32 = 4
    public static let c: UInt32 = 6
    public static let v: UInt32 = 25
    public static let x: UInt32 = 27
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
}

import GuavaUIRuntime

extension EdgeInsets: Interpolatable {
    public static func interpolate(_ a: EdgeInsets, _ b: EdgeInsets, t: Float) -> EdgeInsets {
        EdgeInsets(
            top:      Float.interpolate(a.top,      b.top,      t: t),
            leading:  Float.interpolate(a.leading,  b.leading,  t: t),
            bottom:   Float.interpolate(a.bottom,   b.bottom,   t: t),
            trailing: Float.interpolate(a.trailing, b.trailing, t: t)
        )
    }
}

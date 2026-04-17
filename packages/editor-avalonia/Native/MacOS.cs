using System;
using System.Runtime.InteropServices;

namespace Guava.Editor.Native;

/// <summary>
/// P/Invoke bindings for macOS IOSurface, ObjC runtime, CoreVideo and AppKit.
/// Used to display engine-rendered frames via IOSurface zero-copy sharing.
/// </summary>
public static partial class MacOS
{
    // ── ObjC Runtime ──────────────────────────────────────────────
    private const string ObjCLib = "/usr/lib/libobjc.A.dylib";

    [LibraryImport(ObjCLib, EntryPoint = "objc_getClass", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr objc_getClass(string name);

    [LibraryImport(ObjCLib, EntryPoint = "sel_registerName", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr sel_registerName(string name);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial IntPtr objc_msgSend(IntPtr receiver, IntPtr selector);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial IntPtr objc_msgSend(IntPtr receiver, IntPtr selector, IntPtr arg1);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial IntPtr objc_msgSend(IntPtr receiver, IntPtr selector, int arg1);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial void objc_msgSend_void(IntPtr receiver, IntPtr selector, IntPtr arg1);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial void objc_msgSend_void_float(IntPtr receiver, IntPtr selector, float arg1);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial void objc_msgSend_void_bool(IntPtr receiver, IntPtr selector, [MarshalAs(UnmanagedType.Bool)] bool arg1);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial void objc_msgSend_CGRect(IntPtr receiver, IntPtr selector, CGRect rect);

    // ── IOSurface ─────────────────────────────────────────────────
    private const string IOSurfaceLib = "/System/Library/Frameworks/IOSurface.framework/IOSurface";

    [LibraryImport(IOSurfaceLib)]
    public static partial IntPtr IOSurfaceLookup(uint surfaceId);

    [LibraryImport(IOSurfaceLib)]
    public static partial int IOSurfaceLock(IntPtr surface, uint options, IntPtr seed);

    [LibraryImport(IOSurfaceLib)]
    public static partial int IOSurfaceUnlock(IntPtr surface, uint options, IntPtr seed);

    [LibraryImport(IOSurfaceLib)]
    public static partial int IOSurfaceGetWidth(IntPtr surface);

    [LibraryImport(IOSurfaceLib)]
    public static partial int IOSurfaceGetHeight(IntPtr surface);

    [LibraryImport(IOSurfaceLib)]
    public static partial nint IOSurfaceGetBytesPerRow(IntPtr surface);

    [LibraryImport(IOSurfaceLib)]
    public static partial IntPtr IOSurfaceGetBaseAddress(IntPtr surface);

    // ── CoreFoundation ────────────────────────────────────────────
    private const string CFLib = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

    [LibraryImport(CFLib)]
    public static partial void CFRelease(IntPtr cf);

    // ── QuartzCore ────────────────────────────────────────────────
    private const string QuartzCoreLib = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";

    // ── CoreGraphics ──────────────────────────────────────────────
    [StructLayout(LayoutKind.Sequential)]
    public struct CGRect
    {
        public double X, Y, Width, Height;
        public CGRect(double x, double y, double w, double h) { X = x; Y = y; Width = w; Height = h; }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CGSize
    {
        public double Width, Height;
        public CGSize(double w, double h) { Width = w; Height = h; }
    }

    // ── Helper: create NSView with CALayer showing IOSurface ─────
    public static IntPtr CreateIOSurfaceView(uint surfaceId, double width, double height)
    {
        var surface = IOSurfaceLookup(surfaceId);
        if (surface == IntPtr.Zero)
            throw new InvalidOperationException($"IOSurfaceLookup({surfaceId}) returned null");

        // NSView *view = [[NSView alloc] initWithFrame:rect]
        var NSView = objc_getClass("NSView");
        var alloc = sel_registerName("alloc");
        var initWithFrame = sel_registerName("initWithFrame:");
        var view = objc_msgSend_initWithFrame(
            objc_msgSend(NSView, alloc),
            initWithFrame,
            new CGRect(0, 0, width, height));

        // [view setWantsLayer:YES]
        objc_msgSend_void_bool(view, sel_registerName("setWantsLayer:"), true);

        // CALayer *layer = [view layer]
        var layer = objc_msgSend(view, sel_registerName("layer"));

        // [layer setContents:(id)surface]
        objc_msgSend_void(layer, sel_registerName("setContents:"), surface);

        // [layer setContentsGravity:kCAGravityResizeAspect]
        var gravity = objc_msgSend(objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"),
            Marshal.StringToHGlobalAnsi("resizeAspect"));
        objc_msgSend_void(layer, sel_registerName("setContentsGravity:"), gravity);

        // [layer setOpaque:YES]
        objc_msgSend_void_bool(layer, sel_registerName("setOpaque:"), true);

        return view;
    }

    public static void UpdateIOSurfaceContents(IntPtr nsView, uint surfaceId)
    {
        var surface = IOSurfaceLookup(surfaceId);
        if (surface == IntPtr.Zero) return;

        var layer = objc_msgSend(nsView, sel_registerName("layer"));
        if (layer == IntPtr.Zero) return;

        objc_msgSend_void(layer, sel_registerName("setContents:"), surface);
    }

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    private static partial IntPtr objc_msgSend_initWithFrame(IntPtr receiver, IntPtr selector, CGRect frame);

    [LibraryImport(ObjCLib, EntryPoint = "objc_msgSend")]
    public static partial IntPtr objc_msgSend_stringWithUTF8(IntPtr receiver, IntPtr selector,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string str);
}

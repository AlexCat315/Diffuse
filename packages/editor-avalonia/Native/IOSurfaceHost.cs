using System;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace Guava.Editor.Native;

/// <summary>
/// Displays engine viewport by reading IOSurface pixels into a WriteableBitmap.
/// Renders within Avalonia's visual tree — no airspace issue, overlays work.
/// </summary>
public class IOSurfaceHost : Control
{
    public static readonly StyledProperty<uint> SurfaceIdProperty =
        AvaloniaProperty.Register<IOSurfaceHost, uint>(nameof(SurfaceId));

    static IOSurfaceHost()
    {
        SurfaceIdProperty.Changed.AddClassHandler<IOSurfaceHost>((h, e) => h.OnSurfaceIdChanged((uint)e.NewValue!));
    }

    private uint _surfaceId;
    private WriteableBitmap? _bitmap;
    private DispatcherTimer? _timer;

    public uint SurfaceId
    {
        get => GetValue(SurfaceIdProperty);
        set => SetValue(SurfaceIdProperty, value);
    }

    private void OnSurfaceIdChanged(uint value)
    {
        _surfaceId = value;
        if (value != 0)
        {
            StartRendering();
        }
        else
        {
            _timer?.Stop();
            _timer = null;
            InvalidateVisual();
        }
    }

    private void StartRendering()
    {
        if (_timer != null) return;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) }; // ~60fps
        _timer.Tick += OnTick;
        _timer.Start();
    }

    private void OnTick(object? sender, EventArgs e)
    {
        if (_surfaceId == 0 || Bounds.Width <= 0 || Bounds.Height <= 0) return;

        var surface = MacOS.IOSurfaceLookup(_surfaceId);
        if (surface == IntPtr.Zero) return;

        try
        {
            var w = MacOS.IOSurfaceGetWidth(surface);
            var h = MacOS.IOSurfaceGetHeight(surface);
            if (w <= 0 || h <= 0) return;

            // Create/recreate bitmap if size changed
            if (_bitmap == null || _bitmap.PixelSize.Width != w || _bitmap.PixelSize.Height != h)
            {
                _bitmap?.Dispose();
                _bitmap = new WriteableBitmap(new PixelSize(w, h), new Vector(144, 144),
                    Avalonia.Platform.PixelFormat.Bgra8888, AlphaFormat.Premul);
            }

            // Lock IOSurface and copy pixels
            MacOS.IOSurfaceLock(surface, 1, IntPtr.Zero); // 1 = kIOSurfaceLockReadOnly
            try
            {
                var srcPtr = MacOS.IOSurfaceGetBaseAddress(surface);
                var srcStride = MacOS.IOSurfaceGetBytesPerRow(surface);

                using var fb = _bitmap.Lock();
                var dstPtr = fb.Address;
                var dstStride = fb.RowBytes;
                var copyStride = Math.Min(srcStride, dstStride);

                for (int y = 0; y < h; y++)
                {
                    unsafe
                    {
                        Buffer.MemoryCopy(
                            (void*)(srcPtr + y * srcStride),
                            (void*)(dstPtr + y * dstStride),
                            dstStride, copyStride);
                    }
                }
            }
            finally
            {
                MacOS.IOSurfaceUnlock(surface, 1, IntPtr.Zero);
            }

            InvalidateVisual();
        }
        finally
        {
            MacOS.CFRelease(surface);
        }
    }

    public override void Render(DrawingContext context)
    {
        // Background always filled so adjacent panels don't bleed through.
        context.DrawRectangle(Brushes.Black, null, new Rect(Bounds.Size));

        if (_bitmap != null)
        {
            context.DrawImage(_bitmap,
                new Rect(0, 0, _bitmap.PixelSize.Width, _bitmap.PixelSize.Height),
                new Rect(Bounds.Size));
        }
        // Placeholder text is owned by the view model (StatusText TextBlock) —
        // the host only renders engine pixels.
    }

    protected override Size MeasureOverride(Size availableSize) => availableSize;
    protected override Size ArrangeOverride(Size finalSize) => finalSize;
}

package com.cove.probe;

import android.os.Handler;
import android.os.Looper;
import java.lang.ref.WeakReference;

/** Diagnostics scene work remains responsive while the rendering surface is paused. */
final class Diagnostics {
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static WeakReference<ContentSurfaceView> surface = new WeakReference<>(null);
    static void attach(ContentSurfaceView view) { surface = new WeakReference<>(view); }
    static void schedule(long application) {
        main.post(() -> {
            ContentSurfaceView view = surface.get();
            if (view != null) view.pumpDiagnostics(application);
        });
    }
}

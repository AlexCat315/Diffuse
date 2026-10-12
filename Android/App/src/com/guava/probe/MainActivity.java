package com.guava.probe;

import android.app.Activity;
import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;
import android.os.Bundle;
import android.os.Build;
import android.view.WindowInsets;
import android.widget.FrameLayout;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Android owns the surface and input bridge; the demo paints all UI in Swift. */
public final class MainActivity extends Activity {
    static { System.loadLibrary("GuavaAndroidApp"); }
    static native long open(android.view.Surface surface, int width, int height, float scale, String resources, String checkpoint);
    static native int frame(long session);
    static native void pointer(long session, int kind, float x, float y);
    static native void text(long session, String text, boolean composing);
    static native void key(long session, int scancode);
    static native String snapshot(long session);
    static native void close(long session);
    private DemoSurfaceView surface;
    private final BroadcastReceiver commands = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { acceptCommand(intent); }
    };

    @Override public void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        int orientation = getIntent().getIntExtra("orientation", -1);
        if (orientation >= 0) setRequestedOrientation(orientation);
        try { copyAssets("GuavaAndroid_GuavaUIRendering.bundle", getFilesDir()); }
        catch (IOException error) { throw new IllegalStateException("Cannot unpack shader bundle", error); }
        surface = new DemoSurfaceView(this, savedState == null ? "" : savedState.getString("checkpoint", ""));
        FrameLayout root = new FrameLayout(this);
        root.addView(surface);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        setContentView(root);
        IntentFilter filter = new IntentFilter("com.guava.probe.DEMO_INPUT");
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(commands, filter, Context.RECEIVER_EXPORTED);
        else registerReceiver(commands, filter);
    }

    @Override protected void onResume() { super.onResume(); surface.startFrames(); }
    @Override protected void onPause() { surface.stopFrames(); super.onPause(); }
    @Override protected void onDestroy() { unregisterReceiver(commands); surface.releaseSurface(); super.onDestroy(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        state.putString("checkpoint", surface.checkpoint());
        super.onSaveInstanceState(state);
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        acceptCommand(intent);
    }
    private void acceptCommand(Intent intent) {
        if (intent.hasExtra("orientation")) {
            int orientation = intent.getIntExtra("orientation", -1);
            getIntent().putExtra("orientation", orientation);
            setRequestedOrientation(orientation);
        }
        if ("recreate".equals(intent.getStringExtra("demoAction"))) recreate();
        else surface.debugInput(intent);
    }

    private void copyAssets(String name, File parent) throws IOException {
        String[] children = getAssets().list(name);
        File destination = new File(parent, new File(name).getName());
        if (children != null && children.length > 0) {
            if (!destination.isDirectory() && !destination.mkdirs()) throw new IOException("Cannot create " + destination);
            for (String child : children) copyAssets(name + "/" + child, destination);
        } else {
            try (InputStream input = getAssets().open(name); FileOutputStream output = new FileOutputStream(destination)) {
                byte[] buffer = new byte[16 * 1024];
                for (int length; (length = input.read(buffer)) != -1;) output.write(buffer, 0, length);
            }
        }
    }
}

package com.guava.probe;

import android.app.Activity;
import android.os.Bundle;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Thin platform host; all colored geometry is drawn by Swift NativeRHI/GuavaUI. */
public final class MainActivity extends Activity {
    static { System.loadLibrary("GuavaAndroidApp"); }
    private static native long open(Surface surface, int width, int height, String resources);
    private static native void draw(long session, float x, float y);
    private static native void close(long session);
    private long session;
    private TextView status;

    @Override public void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        // Debug launch argument used by the device lifecycle smoke test.
        int orientation = getIntent().getIntExtra("orientation", -1);
        if (orientation >= 0) setRequestedOrientation(orientation);
        try { copyAssets("GuavaAndroid_GuavaUIRendering.bundle", getFilesDir()); }
        catch (IOException error) { throw new IllegalStateException("Cannot unpack shader bundle", error); }
        FrameLayout root = new FrameLayout(this);
        SurfaceView surface = new SurfaceView(this);
        root.addView(surface);
        status = new TextView(this);
        status.setTextColor(0xffffffff);
        status.setTextSize(18);
        status.setPadding(24, 32, 24, 0);
        status.setText("GuavaUI · Native Vulkan\nSwift 6.4 · tap to redraw");
        root.addView(status, new FrameLayout.LayoutParams(-1, -2));
        setContentView(root);
        surface.getHolder().addCallback(new SurfaceHolder.Callback() {
            @Override public void surfaceCreated(SurfaceHolder holder) {}
            @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                releaseSurface();
                session = open(holder.getSurface(), width, height, getFilesDir().getAbsolutePath());
                if (session == 0) status.setText("Vulkan failed — inspect GuavaAndroid logcat");
                else draw(session, -1, -1);
            }
            @Override public void surfaceDestroyed(SurfaceHolder holder) { releaseSurface(); }
        });
        surface.setOnTouchListener((view, event) -> {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN && session != 0) {
                draw(session, event.getX(), event.getY());
                view.performClick();
            }
            return true;
        });
    }

    private void releaseSurface() {
        if (session != 0) { close(session); session = 0; }
    }

    @Override public void onDestroy() { releaseSurface(); super.onDestroy(); }

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

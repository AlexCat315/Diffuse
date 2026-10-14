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
import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import org.json.JSONObject;

/** Android owns the surface and input bridge; the demo paints all UI in Swift. */
public final class MainActivity extends Activity {
    static { System.loadLibrary("GuavaAndroidApp"); }
    private static boolean sdlReady;
    static native long createApplication(float scale, String resources, String checkpoint, String configuration, String options);
    static native void destroyApplication(long application);
    static native void pumpDiagnostics(long application);
    static void scheduleDiagnostics(long application) { Diagnostics.schedule(application); }
    static native long open(long application, android.view.Surface surface, int width, int height);
    static native int frame(long session, long displayTimeNanos);
    static native void pointer(long session, int kind, float x, float y);
    static native void text(long session, String text, boolean composing);
    static native void key(long session, int scancode, int modifiers);
    static native void scroll(long session, float x, float y, float deltaX, float deltaY);
    static native void keyState(long session, int scancode, boolean down);
    static native void edit(long session, int kind, int start, int end);
    static native String snapshot(long session);
    static native String inputSnapshot(long session);
    static native void close(long session);
    private ContentSurfaceView surface;
    private JSONObject launch;
    private boolean commandsRegistered;
    private boolean debugBuild() { return (getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0; }
    private final BroadcastReceiver commands = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) { acceptCommand(intent); }
    };

    @Override public void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        if (!sdlReady) {
            org.libsdl.app.SDL.setupJNI();
            org.libsdl.app.SDL.initialize();
            org.libsdl.app.SDLActivity.nativeInitMainThread();
            sdlReady = true;
        }
        org.libsdl.app.SDL.setContext(this);
        int orientation = getIntent().getIntExtra("orientation", -1);
        if (orientation >= 0) setRequestedOrientation(orientation);
        try { AssetInstaller.unpack(this); }
        catch (Exception error) { throw new IllegalStateException("Cannot unpack runtime assets", error); }
        try {
            if (savedState != null) launch = new JSONObject(savedState.getString("launch"));
            else {
                try (InputStream input = getAssets().open("launch.json"); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[4096];
                    for (int length; (length = input.read(buffer)) != -1;) output.write(buffer, 0, length);
                    launch = new JSONObject(output.toString("UTF-8"));
                }
            }
            if (debugBuild()) updateLaunch(getIntent());
        } catch (Exception error) { throw new IllegalStateException("Invalid Android launch configuration", error); }
        surface = new ContentSurfaceView(this, savedState == null ? "" : savedState.getString("checkpoint", ""), launch.toString(),
                new RuntimeOptions(this, getIntent()), getLastNonConfigurationInstance() instanceof Long ? (Long)getLastNonConfigurationInstance() : 0);
        FrameLayout root = new FrameLayout(this);
        root.addView(surface);
        if ("game".equals(launch.optString("mode"))) root.addView(new GameControls(this, surface), GameControls.layout());
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
        if (debugBuild()) {
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(commands, filter, Context.RECEIVER_EXPORTED);
            else registerReceiver(commands, filter);
            commandsRegistered = true;
        }
    }

    @Override protected void onResume() {
        super.onResume();
        RuntimeLog.info("com.guava.android.lifecycle", "Activity resumed");
        surface.startFrames();
    }
    @Override protected void onPause() {
        surface.stopFrames();
        RuntimeLog.info("com.guava.android.lifecycle", "Activity paused");
        RuntimeLog.flush();
        super.onPause();
    }
    @Override protected void onDestroy() { if (commandsRegistered) unregisterReceiver(commands); surface.releaseSurface(); if (!isChangingConfigurations()) surface.closeApplication(); super.onDestroy(); }
    @Override public Object onRetainNonConfigurationInstance() { return surface.detachApplication(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        state.putString("checkpoint", surface.checkpoint());
        state.putString("launch", launch.toString());
        super.onSaveInstanceState(state);
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (debugBuild()) acceptCommand(intent);
    }
    private void acceptCommand(Intent intent) {
        boolean sceneChanged = intent.hasExtra("mode") || intent.hasExtra("component");
        if (sceneChanged || RuntimeOptions.updates(intent)) {
            updateLaunch(intent);
            RuntimeOptions.merge(intent, getIntent());
            RuntimeOptions options = new RuntimeOptions(this, getIntent());
            if (sceneChanged) surface.configure(launch.toString(), options);
            else surface.configureRuntime(options);
        }
        if (intent.hasExtra("orientation")) {
            int orientation = intent.getIntExtra("orientation", -1);
            getIntent().putExtra("orientation", orientation);
            setRequestedOrientation(orientation);
        }
        if ("recreate".equals(intent.getStringExtra("demoAction"))) recreate();
        else surface.debugInput(intent);
    }

    private void updateLaunch(Intent intent) {
        try {
            for (String key : new String[]{"mode", "component"}) {
                if (intent.hasExtra(key)) launch.put(key, intent.getStringExtra(key));
            }
        } catch (Exception error) { throw new IllegalArgumentException("Invalid demo mode", error); }
    }

}

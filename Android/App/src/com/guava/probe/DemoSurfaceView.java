package com.guava.probe;

import android.content.Context;
import android.content.Intent;
import android.text.InputType;
import android.view.Choreographer;
import android.view.KeyEvent;
import android.view.KeyCharacterMap;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** A vsync-driven host; Swift skips GPU work while Compose and the tree are clean. */
final class DemoSurfaceView extends SurfaceView implements SurfaceHolder.Callback, Choreographer.FrameCallback {
    private long session;
    private long application;
    private String checkpoint;
    private boolean running;
    private boolean callbackPending;
    private DemoInputConnection connection;
    private String configuration;
    private RuntimeOptions options;
    private FramePacing pacing;
    private long lastSnapshotTime;
    private boolean gameMode;
    private final boolean debugBuild;
    private float touchX, touchY;
    private boolean touchMoved;
    private long touchStarted;

    DemoSurfaceView(Context context, String checkpoint, String configuration, RuntimeOptions options, long application) {
        super(context);
        this.checkpoint = checkpoint;
        this.configuration = configuration;
        this.application = application;
        this.options = options;
        pacing = new FramePacing(options.timings);
        debugBuild = (context.getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        gameMode = configuration.contains("\"game\"");
        setFocusable(true);
        setFocusableInTouchMode(true);
        getHolder().addCallback(this);
    }
    void configure(String configuration, RuntimeOptions options) {
        releaseSurface();
        closeApplication();
        this.configuration = configuration;
        this.options = options;
        pacing = new FramePacing(options.timings);
        lastSnapshotTime = 0;
        gameMode = configuration.contains("\"game\"");
        checkpoint = "";
        openSurface();
        schedule();
    }

    void configureRuntime(RuntimeOptions options) {
        if (!this.options.sameNativeConfiguration(options)) { configure(configuration, options); return; }
        this.options = options;
        if (debugBuild && options.snapshots && !options.benchmark && session != 0) saveSnapshot();
    }

    void startFrames() { running = true; pacing = new FramePacing(options.timings); openSurface(); schedule(); }
    void stopFrames() {
        running = false;
        Choreographer.getInstance().removeFrameCallback(this);
        callbackPending = false;
        releaseSurface();
    }
    private void schedule() {
        if (running && session != 0 && !callbackPending) {
            callbackPending = true;
            Choreographer.getInstance().postFrameCallback(this);
        }
    }
    @Override public void doFrame(long timestamp) {
        callbackPending = false;
        if (!running || session == 0) return;
        long started = options.timings ? System.nanoTime() : 0;
        int result = MainActivity.frame(session, timestamp);
        if (result < 0) { stopFrames(); return; }
        if (result > 0 && debugBuild && options.snapshots && !options.benchmark && (timestamp - lastSnapshotTime > 200000000L || !gameMode)) {
            saveSnapshot(); lastSnapshotTime = timestamp;
        }
        if (options.timings) pacing.record(timestamp, started, System.nanoTime(), result > 0,
                getDisplay() == null ? 60 : getDisplay().getRefreshRate());
        schedule();
    }
    @Override public void surfaceCreated(SurfaceHolder holder) {}
    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        releaseSurface();
        openSurface();
        schedule();
    }
    private void openSurface() {
        if (!running || session != 0 || getWidth() <= 0 || getHeight() <= 0 || !getHolder().getSurface().isValid()) return;
        if (application == 0) application = MainActivity.createApplication(getResources().getDisplayMetrics().density,
                AssetInstaller.root(getContext()).getAbsolutePath(), checkpoint, configuration, options.json());
        if (application != 0) session = MainActivity.open(application, getHolder().getSurface(), getWidth(), getHeight());
    }
    @Override public void surfaceDestroyed(SurfaceHolder holder) { releaseSurface(); }
    void releaseSurface() {
        if (session != 0) {
            checkpoint = checkpoint();
            MainActivity.close(session);
            session = 0;
            connection = null;
        }
    }
    void closeApplication() { if (application != 0) { MainActivity.destroyApplication(application); application = 0; } }
    long detachApplication() { releaseSurface(); long retained = application; application = 0; return retained; }
    private JSONObject state() {
        try { return new JSONObject(session == 0 ? "{}" : MainActivity.snapshot(session)); }
        catch (Exception error) { throw new IllegalStateException("Invalid Swift demo state", error); }
    }
    JSONObject inputState() {
        try { return new JSONObject(session == 0 ? "{}" : MainActivity.inputSnapshot(session)); }
        catch (Exception error) { throw new IllegalStateException("Invalid Swift input state", error); }
    }
    String checkpoint() {
        JSONObject value = state().optJSONObject("state");
        return value == null ? checkpoint : value.toString();
    }
    private JSONObject editor() { JSONObject editor = inputState().optJSONObject("editor"); return editor == null ? new JSONObject() : editor; }
    private boolean textFocused() { return inputState().optJSONObject("editor") != null; }
    void edit(int kind, int start, int end) { if (session != 0) MainActivity.edit(session, kind, start, end); }
    void text(String value, boolean composing) { if (session != 0) MainActivity.text(session, value, composing); }
    void key(int scancode) { if (session != 0) MainActivity.key(session, scancode, 0); }
    void keyState(int scancode, boolean down) { if (session != 0) MainActivity.keyState(session, scancode, down); }

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (session == 0) return false;
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            touchX = event.getX(); touchY = event.getY(); touchMoved = false;
            touchStarted = event.getEventTime();
            requestFocus();
            JSONObject previousState = inputState();
            boolean previous = previousState.optJSONObject("editor") != null;
            String previousID = previousState.optString("focused");
            MainActivity.pointer(session, 0, event.getX(), event.getY());
            JSONObject currentState = inputState();
            InputMethodManager ime = (InputMethodManager)getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
            if (currentState.optJSONObject("editor") != null) {
                if (!previous || !previousID.equals(currentState.optString("focused"))) { connection = null; ime.restartInput(this); }
                ime.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
            } else if (previous) { ime.hideSoftInputFromWindow(getWindowToken(), 0); connection = null; }
        } else if (action == MotionEvent.ACTION_UP) {
            // Use the completed gesture's event times. A slow debug GPU frame
            // can delay/coalesce MOVE delivery past a wall-clock long-press timer.
            int slop = android.view.ViewConfiguration.get(getContext()).getScaledTouchSlop();
            boolean stationary = !touchMoved && Math.abs(event.getX()-touchX)+Math.abs(event.getY()-touchY)<=slop;
            boolean contextPress = !gameMode && stationary && event.getEventTime()-touchStarted >= android.view.ViewConfiguration.getLongPressTimeout();
            MainActivity.pointer(session, contextPress ? 4 : 1, event.getX(), event.getY());
            if (connection != null) connection.updateSelection();
            performClick();
        } else if (action == MotionEvent.ACTION_MOVE) {
            int slop = android.view.ViewConfiguration.get(getContext()).getScaledTouchSlop();
            if (Math.abs(event.getX()-touchX)+Math.abs(event.getY()-touchY)>slop) touchMoved = true;
            MainActivity.pointer(session, 2, event.getX(), event.getY());
        } else if (action == MotionEvent.ACTION_CANCEL) { MainActivity.pointer(session, 3, event.getX(), event.getY()); }
        return true;
    }
    @Override public boolean performClick() { super.performClick(); return true; }
    @Override public boolean onCheckIsTextEditor() { return session != 0 && textFocused(); }
    @Override public InputConnection onCreateInputConnection(EditorInfo info) {
        if (!onCheckIsTextEditor()) return null;
        info.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES;
        info.imeOptions = EditorInfo.IME_ACTION_DONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        JSONObject editor = editor();
        if (editor.optBoolean("isSecure")) info.inputType |= InputType.TYPE_TEXT_VARIATION_PASSWORD;
        if (editor.optBoolean("isMultiline")) {
            info.inputType |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
            info.imeOptions = EditorInfo.IME_ACTION_NONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        }
        info.initialSelStart = editor.optInt("selectionStart"); info.initialSelEnd = editor.optInt("selectionEnd");
        connection = new DemoInputConnection(this);
        return connection;
    }
    @Override public boolean onKeyDown(int code, KeyEvent event) {
        int gameKey = GameControls.scancode(code);
        if (gameMode && gameKey != 0) { keyState(gameKey, true); return true; }
        if (textFocused() && (event.isCtrlPressed() || event.isMetaPressed())) {
            int action = code == KeyEvent.KEYCODE_A ? android.R.id.selectAll : code == KeyEvent.KEYCODE_C ? android.R.id.copy
                : code == KeyEvent.KEYCODE_X ? android.R.id.cut : code == KeyEvent.KEYCODE_V ? android.R.id.paste : 0;
            if (action != 0) {
                if (connection == null) connection = new DemoInputConnection(this);
                return connection.performContextMenuAction(action);
            }
        }
        int navigation = AndroidKeys.scancode(code);
        if (navigation != 0 || event.isCtrlPressed() || event.isMetaPressed()) {
            int scan = navigation != 0 ? navigation : code >= KeyEvent.KEYCODE_A && code <= KeyEvent.KEYCODE_Z ? 4 + code - KeyEvent.KEYCODE_A : 0;
            if (scan != 0) { MainActivity.key(session, scan, AndroidKeys.modifiers(event)); return true; }
        }
        if (code == KeyEvent.KEYCODE_DEL) { key(42); return true; }
        if (code == KeyEvent.KEYCODE_TAB) { key(43); return true; }
        if (code == KeyEvent.KEYCODE_ENTER) { key(40); return true; }
        int unicode = event.getUnicodeChar();
        if (unicode > 0 && (unicode & KeyCharacterMap.COMBINING_ACCENT) == 0) {
            if (textFocused()) text(new String(Character.toChars(unicode)), false);
            else if (code == KeyEvent.KEYCODE_SPACE) key(44);
            return true;
        }
        return super.onKeyDown(code, event);
    }
    @Override public boolean onGenericMotionEvent(MotionEvent event) {
        if (session == 0) return false;
        if (event.getActionMasked() == MotionEvent.ACTION_SCROLL) {
            MainActivity.scroll(session, event.getX(), event.getY(), event.getAxisValue(MotionEvent.AXIS_HSCROLL), event.getAxisValue(MotionEvent.AXIS_VSCROLL));
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_HOVER_MOVE) { MainActivity.pointer(session, 5, event.getX(), event.getY()); return true; }
        return super.onGenericMotionEvent(event);
    }
    @Override public boolean onKeyUp(int code, KeyEvent event) {
        int gameKey = GameControls.scancode(code);
        if (gameMode && gameKey != 0) { keyState(gameKey, false); return true; }
        return super.onKeyUp(code, event);
    }
    // Debug-only APK automation goes through the same InputConnection as the IME.
    void debugInput(Intent intent) {
        if ("snapshot".equals(intent.getStringExtra("demoAction"))) { saveSnapshot(); return; }
        if ("keyDown".equals(intent.getStringExtra("demoAction")) || "keyUp".equals(intent.getStringExtra("demoAction"))) {
            keyState(intent.getIntExtra("scancode", 0), "keyDown".equals(intent.getStringExtra("demoAction"))); return;
        }
        if (!textFocused()) return;
        if (connection == null) connection = new DemoInputConnection(this);
        String action = intent.getStringExtra("demoAction");
        String value = intent.getStringExtra("text");
        if ("compose".equals(action)) connection.setComposingText(value == null ? "" : value, 1);
        else if ("commit".equals(action)) connection.commitText(value == null ? "" : value, 1);
        else if ("finish".equals(action)) connection.finishComposingText();
        else if ("delete".equals(action)) connection.deleteSurroundingText(1, 0);
        else if ("select".equals(action)) connection.setSelection(intent.getIntExtra("start", 0), intent.getIntExtra("end", 0));
    }
    private void saveSnapshot() {
        File destination = new File(getContext().getFilesDir(), "demo-state.json");
        File temporary = new File(getContext().getFilesDir(), "demo-state.tmp");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            JSONObject report = state();
            int[] origin = new int[2];
            getLocationOnScreen(origin);
            JSONObject bounds = new JSONObject();
            bounds.put("x", origin[0]); bounds.put("y", origin[1]);
            bounds.put("width", getWidth()); bounds.put("height", getHeight());
            report.put("surface", bounds);
            output.write(report.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) { throw new IllegalStateException("Cannot write demo report", error); }
        if (!temporary.renameTo(destination)) throw new IllegalStateException("Cannot publish demo report");
    }
}

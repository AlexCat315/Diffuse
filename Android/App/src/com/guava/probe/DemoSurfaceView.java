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
    private String checkpoint;
    private boolean running;
    private boolean callbackPending;
    private DemoInputConnection connection;

    DemoSurfaceView(Context context, String checkpoint) {
        super(context);
        this.checkpoint = checkpoint;
        setFocusable(true);
        setFocusableInTouchMode(true);
        getHolder().addCallback(this);
    }

    void startFrames() { running = true; openSurface(); schedule(); }
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
        int result = MainActivity.frame(session);
        if (result < 0) { stopFrames(); return; }
        if (result > 0) saveSnapshot();
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
        session = MainActivity.open(getHolder().getSurface(), getWidth(), getHeight(), getResources().getDisplayMetrics().density,
                                    getContext().getFilesDir().getAbsolutePath(), checkpoint);
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
    JSONObject state() {
        try { return new JSONObject(session == 0 ? "{}" : MainActivity.snapshot(session)); }
        catch (Exception error) { throw new IllegalStateException("Invalid Swift demo state", error); }
    }
    String checkpoint() {
        JSONObject value = state().optJSONObject("state");
        return value == null ? checkpoint : value.toString();
    }
    String note() { JSONObject value = state().optJSONObject("state"); return value == null ? "" : value.optString("note", ""); }
    private boolean textFocused() { return "counter.note".equals(state().optString("focused", "")); }
    void text(String value, boolean composing) { if (session != 0) MainActivity.text(session, value, composing); }
    void key(int scancode) { if (session != 0) MainActivity.key(session, scancode); }

    @Override public boolean onTouchEvent(MotionEvent event) {
        if (session == 0) return false;
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            requestFocus();
            boolean previous = textFocused();
            MainActivity.pointer(session, 0, event.getX(), event.getY());
            InputMethodManager ime = (InputMethodManager)getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
            if (textFocused()) {
                if (!previous) ime.restartInput(this);
                ime.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT);
            } else if (previous) { ime.hideSoftInputFromWindow(getWindowToken(), 0); connection = null; }
        } else if (action == MotionEvent.ACTION_UP) {
            MainActivity.pointer(session, 1, event.getX(), event.getY());
            performClick();
        } else if (action == MotionEvent.ACTION_MOVE) MainActivity.pointer(session, 2, event.getX(), event.getY());
        else if (action == MotionEvent.ACTION_CANCEL) MainActivity.pointer(session, 3, event.getX(), event.getY());
        return true;
    }
    @Override public boolean performClick() { super.performClick(); return true; }
    @Override public boolean onCheckIsTextEditor() { return session != 0 && textFocused(); }
    @Override public InputConnection onCreateInputConnection(EditorInfo info) {
        if (!onCheckIsTextEditor()) return null;
        info.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES;
        info.imeOptions = EditorInfo.IME_ACTION_DONE | EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        info.initialSelStart = info.initialSelEnd = note().length();
        connection = new DemoInputConnection(this);
        return connection;
    }
    @Override public boolean onKeyDown(int code, KeyEvent event) {
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
    // Debug-only APK automation goes through the same InputConnection as the IME.
    void debugInput(Intent intent) {
        if (!textFocused()) return;
        if (connection == null) connection = new DemoInputConnection(this);
        String action = intent.getStringExtra("demoAction");
        String value = intent.getStringExtra("text");
        if ("compose".equals(action)) connection.setComposingText(value == null ? "" : value, 1);
        else if ("commit".equals(action)) connection.commitText(value == null ? "" : value, 1);
        else if ("finish".equals(action)) connection.finishComposingText();
        else if ("delete".equals(action)) connection.deleteSurroundingText(1, 0);
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

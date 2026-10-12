package com.guava.probe;

import android.content.Context;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;

/** A simultaneous-touch keyboard control strip for exported desktop-input games. */
final class GameControls extends LinearLayout {
    GameControls(Context context, DemoSurfaceView surface) {
        super(context);
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER);
        setAlpha(0.8f);
        String[] labels = {"← A", "↑ W", "↓ S", "D →", "Sprint", "Start", "Restart"};
        int[] keys = {4, 26, 22, 7, 225, 44, 21};
        for (int index = 0; index < keys.length; index++) {
            final int key = keys[index];
            Button button = new Button(context);
            button.setText(labels[index]);
            button.setFocusable(false);
            button.setOnTouchListener((view, event) -> {
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN: surface.keyState(key, true); return true;
                    case MotionEvent.ACTION_UP: case MotionEvent.ACTION_CANCEL: surface.keyState(key, false); return true;
                    default: return true;
                }
            });
            addView(button, new LinearLayout.LayoutParams(0, LayoutParams.WRAP_CONTENT, 1));
        }
    }
    static FrameLayout.LayoutParams layout() {
        return new FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM);
    }
    static int scancode(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_A: case KeyEvent.KEYCODE_DPAD_LEFT: return 4;
            case KeyEvent.KEYCODE_D: case KeyEvent.KEYCODE_DPAD_RIGHT: return 7;
            case KeyEvent.KEYCODE_W: case KeyEvent.KEYCODE_DPAD_UP: return 26;
            case KeyEvent.KEYCODE_S: case KeyEvent.KEYCODE_DPAD_DOWN: return 22;
            case KeyEvent.KEYCODE_R: return 21;
            case KeyEvent.KEYCODE_SPACE: case KeyEvent.KEYCODE_BUTTON_A: return 44;
            case KeyEvent.KEYCODE_SHIFT_LEFT: case KeyEvent.KEYCODE_BUTTON_B: return 225;
            default: return 0;
        }
    }
}

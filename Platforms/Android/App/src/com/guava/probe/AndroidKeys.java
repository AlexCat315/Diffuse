package com.guava.probe;
import android.view.KeyEvent;

final class AndroidKeys {
    static int modifiers(KeyEvent event) {
        return (event.isShiftPressed() ? 1 : 0) | (event.isCtrlPressed() ? 4 : 0)
            | (event.isAltPressed() ? 16 : 0) | (event.isMetaPressed() ? 64 : 0);
    }
    static int scancode(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_LEFT: return 80;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 79;
            case KeyEvent.KEYCODE_DPAD_UP: return 82;
            case KeyEvent.KEYCODE_DPAD_DOWN: return 81;
            case KeyEvent.KEYCODE_MOVE_HOME: return 74;
            case KeyEvent.KEYCODE_MOVE_END: return 77;
            case KeyEvent.KEYCODE_PAGE_UP: return 75;
            case KeyEvent.KEYCODE_PAGE_DOWN: return 78;
            case KeyEvent.KEYCODE_FORWARD_DEL: return 76;
            case KeyEvent.KEYCODE_ESCAPE: return 41;
            case KeyEvent.KEYCODE_TAB: return 43;
            case KeyEvent.KEYCODE_ENTER: return 40;
            case KeyEvent.KEYCODE_DEL: return 42;
            default: return 0;
        }
    }
}

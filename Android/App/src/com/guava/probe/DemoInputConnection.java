package com.guava.probe;

import android.content.Context;
import android.text.Editable;
import android.text.Selection;
import android.text.SpannableStringBuilder;
import android.view.KeyEvent;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;

/** SharedCounter's note edits at the end; this does not implement the full TextField editor. */
final class DemoInputConnection extends BaseInputConnection {
    private final DemoSurfaceView view;
    private final Editable editable = new SpannableStringBuilder();
    private String composing = "";

    DemoInputConnection(DemoSurfaceView view) { super(view, true); this.view = view; }
    @Override public Editable getEditable() {
        editable.replace(0, editable.length(), view.note());
        if (!composing.isEmpty()) {
            SpannableStringBuilder pending = new SpannableStringBuilder(composing);
            setComposingSpans(pending);
            editable.append(pending);
        }
        Selection.setSelection(editable, editable.length());
        return editable;
    }
    @Override public boolean commitText(CharSequence text, int cursor) {
        view.text(text.toString(), false);
        composing = "";
        updateSelection();
        return true;
    }
    @Override public boolean setComposingText(CharSequence text, int cursor) {
        composing = text.toString();
        view.text(composing, true);
        updateSelection();
        return true;
    }
    @Override public boolean finishComposingText() {
        if (!composing.isEmpty()) view.text(composing, false);
        composing = "";
        view.text("", true);
        updateSelection();
        return true;
    }
    @Override public boolean deleteSurroundingText(int before, int after) {
        if (before < 0 || after != 0) return false;
        int remaining = Math.min(before, (view.note() + composing).length());
        while (remaining > 0) {
            if (!composing.isEmpty()) {
                int start = composing.offsetByCodePoints(composing.length(), -1);
                remaining -= composing.length() - start;
                composing = composing.substring(0, start);
                view.text(composing, true);
            } else {
                int length = view.note().length();
                view.key(42);
                int removed = length - view.note().length();
                if (removed <= 0) break;
                remaining -= removed;
            }
        }
        updateSelection();
        return true;
    }
    @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) {
        String text = view.note() + composing;
        int count = Math.min(Math.max(0, before), text.codePointCount(0, text.length()));
        int start = text.offsetByCodePoints(text.length(), -count);
        return deleteSurroundingText(text.length() - start, after);
    }
    @Override public CharSequence getTextBeforeCursor(int length, int flags) {
        String text = view.note() + composing;
        int start = Math.max(0, text.length() - Math.max(0, length));
        if (start > 0 && start < text.length() && Character.isLowSurrogate(text.charAt(start))) start--;
        return text.substring(start);
    }
    @Override public CharSequence getTextAfterCursor(int length, int flags) { return ""; }
    @Override public CharSequence getSelectedText(int flags) { return ""; }
    @Override public boolean setSelection(int start, int end) {
        int length = (view.note() + composing).length();
        return start == length && end == length;
    }
    @Override public boolean sendKeyEvent(KeyEvent event) {
        return event.getAction() != KeyEvent.ACTION_DOWN || view.onKeyDown(event.getKeyCode(), event);
    }
    @Override public boolean performEditorAction(int action) {
        if (action != EditorInfo.IME_ACTION_DONE) return false;
        finishComposingText();
        InputMethodManager ime = (InputMethodManager)view.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        ime.hideSoftInputFromWindow(view.getWindowToken(), 0);
        return true;
    }
    private void updateSelection() {
        int length = view.note().length() + composing.length();
        int start = composing.isEmpty() ? -1 : view.note().length();
        InputMethodManager ime = (InputMethodManager)view.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        ime.updateSelection(view, length, length, start, composing.isEmpty() ? -1 : length);
    }
}

package com.guava.probe;

import android.content.Context;
import android.text.Editable;
import android.text.Selection;
import android.text.SpannableStringBuilder;
import android.view.KeyEvent;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import org.json.JSONObject;

/** Mirrors the focused Swift editor; UTF-16 selection maps to its grapheme-safe edits. */
final class DemoInputConnection extends BaseInputConnection {
    private final DemoSurfaceView view;
    private final Editable editable = new SpannableStringBuilder();
    private String composing = "";
    private final String editorID;

    DemoInputConnection(DemoSurfaceView view) { super(view, true); this.view = view; editorID = view.inputState().optString("focused"); }
    private boolean valid() { return editorID.equals(view.inputState().optString("focused")); }
    private JSONObject state() {
        JSONObject input = view.inputState();
        JSONObject editor = editorID.equals(input.optString("focused")) ? input.optJSONObject("editor") : null;
        return editor == null ? new JSONObject() : editor;
    }
    private int start(JSONObject state) { return Math.min(state.optInt("selectionStart"), state.optInt("selectionEnd")); }
    private int end(JSONObject state) { return Math.max(state.optInt("selectionStart"), state.optInt("selectionEnd")); }
    @Override public Editable getEditable() {
        JSONObject state = state();
        String text = state.optString("text");
        editable.replace(0, editable.length(), text);
        removeComposingSpans(editable);
        int from = state.optInt("compositionStart", -1), to = state.optInt("compositionEnd", -1);
        if (from >= 0 && to >= from && to <= editable.length()) {
            SpannableStringBuilder pending = new SpannableStringBuilder(text.substring(from, to));
            setComposingSpans(pending);
            editable.replace(from, to, pending);
        }
        Selection.setSelection(editable, Math.min(start(state), editable.length()), Math.min(end(state), editable.length()));
        return editable;
    }
    @Override public boolean commitText(CharSequence text, int cursor) {
        if (!valid()) return false;
        JSONObject before = state();
        int insertion = before.optInt("compositionStart", -1) >= 0 ? before.optInt("compositionStart") : start(before);
        view.text(text.toString(), false);
        composing = "";
        moveCursor(cursor, insertion);
        updateSelection();
        return true;
    }
    @Override public boolean setComposingText(CharSequence text, int cursor) {
        if (!valid()) return false;
        composing = text.toString();
        JSONObject before = state();
        int insertion = before.optInt("compositionStart", -1) >= 0 ? before.optInt("compositionStart") : start(before);
        view.text(composing, true);
        moveCursor(cursor, insertion);
        updateSelection();
        return true;
    }
    @Override public boolean finishComposingText() {
        if (!valid()) { composing = ""; return true; }
        if (!composing.isEmpty()) view.text(composing, false);
        composing = "";
        view.text("", true);
        updateSelection();
        return true;
    }
    @Override public boolean deleteSurroundingText(int before, int after) {
        if (!valid()) return false;
        if (before < 0 || after < 0 || before > 32768 || after > 32768) return false;
        if (!composing.isEmpty() && after == 0) {
            int from = Math.max(0, composing.length() - before);
            if (from > 0 && Character.isLowSurrogate(composing.charAt(from))) from--;
            composing = composing.substring(0, from);
            view.text(composing, true);
        } else view.edit(1, before, after);
        updateSelection();
        return true;
    }
    @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) {
        if (before < 0 || after < 0) return false;
        JSONObject state = state();
        String text = state.optString("text");
        int left = start(state), right = end(state);
        int from = text.offsetByCodePoints(left, -Math.min(before, text.codePointCount(0, left)));
        int to = text.offsetByCodePoints(right, Math.min(after, text.codePointCount(right, text.length())));
        return deleteSurroundingText(left - from, to - right);
    }
    @Override public CharSequence getTextBeforeCursor(int length, int flags) {
        JSONObject state = state(); String text = state.optString("text");
        int end = start(state), from = Math.max(0, end - Math.max(0, length));
        if (from > 0 && from < text.length() && Character.isLowSurrogate(text.charAt(from))) from--;
        return text.substring(from, end);
    }
    @Override public CharSequence getTextAfterCursor(int length, int flags) {
        JSONObject state = state(); String text = state.optString("text");
        int from = end(state), to = Math.min(text.length(), from + Math.max(0, length));
        if (to < text.length() && to > 0 && Character.isLowSurrogate(text.charAt(to))) to++;
        return text.substring(from, to);
    }
    @Override public CharSequence getSelectedText(int flags) {
        JSONObject state = state(); return state.optString("text").substring(start(state), end(state));
    }
    @Override public boolean setSelection(int start, int end) {
        if (!valid()) return false;
        if (start < 0 || end < 0 || start > state().optString("text").length() || end > state().optString("text").length()) return false;
        view.edit(0, start, end);
        if (state().optInt("compositionStart", -1) < 0) composing = "";
        updateSelection(); return true;
    }
    @Override public boolean sendKeyEvent(KeyEvent event) {
        return event.getAction() == KeyEvent.ACTION_DOWN ? view.onKeyDown(event.getKeyCode(), event) : view.onKeyUp(event.getKeyCode(), event);
    }
    @Override public boolean performEditorAction(int action) {
        if (action != EditorInfo.IME_ACTION_DONE) return false;
        finishComposingText();
        ((InputMethodManager)view.getContext().getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(view.getWindowToken(), 0);
        return true;
    }
    @Override public boolean performContextMenuAction(int action) {
        if (!valid()) return false;
        JSONObject state = state();
        if (action == android.R.id.selectAll) return setSelection(0, state.optString("text").length());
        if (action == android.R.id.undo || action == android.R.id.redo) {
            view.edit(action == android.R.id.undo ? 2 : 3, 0, 0); updateSelection(); return true;
        }
        android.content.ClipboardManager clipboard = (android.content.ClipboardManager)view.getContext().getSystemService(Context.CLIPBOARD_SERVICE);
        if (action == android.R.id.copy || action == android.R.id.cut) {
            if (state.optBoolean("isSecure") || (action == android.R.id.cut && state.optBoolean("isReadOnly"))) return false;
            clipboard.setPrimaryClip(android.content.ClipData.newPlainText("GuavaUI", getSelectedText(0)));
            if (action == android.R.id.cut) { view.edit(1, 0, 0); updateSelection(); }
            return true;
        }
        if (action == android.R.id.paste) {
            if (state.optBoolean("isReadOnly") || !clipboard.hasPrimaryClip()) return false;
            CharSequence text = clipboard.getPrimaryClip().getItemAt(0).coerceToText(view.getContext());
            if (text.length() > 32768) return false;
            return commitText(text, 1);
        }
        return false;
    }
    private void moveCursor(int requested, int insertion) {
        if (requested == 1) return;
        JSONObject state = state();
        int next = requested > 0 ? end(state) + requested - 1 : insertion + requested;
        next = Math.max(0, Math.min(state.optString("text").length(), next));
        view.edit(0, next, next);
    }
    void updateSelection() {
        JSONObject state = state();
        ((InputMethodManager)view.getContext().getSystemService(Context.INPUT_METHOD_SERVICE)).updateSelection(view,
            start(state), end(state), state.optInt("compositionStart", -1), state.optInt("compositionEnd", -1));
    }
}

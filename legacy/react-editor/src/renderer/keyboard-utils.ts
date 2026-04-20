/**
 * Check whether a keyboard event target is in a text-editing context.
 *
 * Returns `true` when the user is typing into any kind of text input —
 * native `<input>`/`<textarea>`, `contentEditable` elements, or embedded
 * code editors (Monaco, CodeMirror, Ace, etc.) — so that global keyboard
 * shortcuts (Q/W/E/R, Space, Delete …) are **not** intercepted.
 *
 * Usage:
 *   window.addEventListener("keydown", (e) => {
 *     if (isTextEditingTarget(e)) return;   // let the editor handle it
 *     // …handle global shortcuts…
 *   });
 */
export function isTextEditingTarget(e: KeyboardEvent): boolean {
  const el = e.target;
  if (!(el instanceof HTMLElement)) return false;

  // Native text inputs
  if (el instanceof HTMLInputElement) {
    const type = el.type.toLowerCase();
    // Only text-ish input types; buttons / checkboxes / etc. are fine
    return type === "" || type === "text" || type === "search" || type === "url"
      || type === "tel" || type === "email" || type === "password" || type === "number";
  }
  if (el instanceof HTMLTextAreaElement) return true;

  // contentEditable regions
  if (el.isContentEditable) return true;

  // Embedded code editors — walk up the DOM looking for known container classes.
  // This covers Monaco, CodeMirror 5/6, Ace, and any future editor that
  // wraps a hidden textarea inside a characteristic container.
  const editorSelectors = ".monaco-editor, .cm-editor, .CodeMirror, .ace_editor";
  if (el.closest(editorSelectors)) return true;

  return false;
}

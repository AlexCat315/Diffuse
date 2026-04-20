import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default [
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    // Warn when useState is used inside panel components.
    // Panel state should use useSyncedState() for cross-window sync,
    // or useLocalState() for window-local ephemeral state.
    files: ["src/renderer/panels/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-syntax": [
        "warn",
        {
          selector: "CallExpression[callee.name='useState']",
          message:
            "面板组件请使用 useSyncedState() 代替 useState() 以支持多窗口状态同步，" +
            "或使用 useLocalState() 标记为窗口本地状态。",
        },
      ],
    },
  },
  {
    ignores: ["dist/**", "native/**", "node_modules/**"],
  },
];

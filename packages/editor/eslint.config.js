import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default [
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    // Warn when useState is used inside panel components.
    // Panel state should use usePanelSetting() for cross-window sync.
    files: ["src/renderer/panels/**/*.{ts,tsx}"],
    rules: {
      "no-restricted-syntax": [
        "warn",
        {
          selector: "CallExpression[callee.name='useState']",
          message:
            "面板组件请使用 usePanelSetting() 代替 useState()，以支持多窗口状态同步。" +
            "如果此状态确实不需要同步（如 hover、loading），可添加 // eslint-disable-next-line 注释。",
        },
      ],
    },
  },
  {
    ignores: ["dist/**", "native/**", "node_modules/**"],
  },
];

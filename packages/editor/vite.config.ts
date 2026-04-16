import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

const root = path.resolve(__dirname);
const placeholderIconDataUrl = (() => {
  const svg = [
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">',
    '<rect x="4" y="4" width="16" height="16" rx="3" fill="black"/>',
    '<path d="M8 8h8v8H8z" fill="white"/>',
    '</svg>',
  ].join("");
  return `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`;
})();

export default defineConfig({
  root: path.resolve(__dirname, "src/renderer"),
  base: "./",
  publicDir: path.resolve(root, "public"),
  plugins: [
    {
      name: "citron-icon-fallback",
      enforce: "pre",
      resolveId(source) {
        if (source.startsWith("@icons/")) {
          return `\0citron-icon:${source}`;
        }
        return null;
      },
      load(id) {
        if (id.startsWith("\0citron-icon:")) {
          return `export default ${JSON.stringify(placeholderIconDataUrl)};`;
        }
        return null;
      },
    },
    react(),
    // Runtime JS (citron-bridge.js + 子模块) 由 V8 binding 在 onContextCreated 时注入，
    // 无需通过 <script> 标签重复加载。
  ],
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
  },
  build: {
    outDir: path.resolve(root, "dist-citron"),
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      "@shared": path.resolve(root, "src/shared"),
    },
  },
});

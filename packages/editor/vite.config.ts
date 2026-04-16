import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

const root = path.resolve(__dirname);

export default defineConfig({
  root: path.resolve(__dirname, "src/renderer"),
  base: "./",
  publicDir: path.resolve(root, "public"),
  plugins: [
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
      "@icons": path.resolve(root, "assets/icons/svg"),
      "@shared": path.resolve(root, "src/shared"),
    },
  },
});

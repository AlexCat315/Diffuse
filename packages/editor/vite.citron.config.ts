import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

const root = path.resolve(__dirname);

export default defineConfig({
  root: path.resolve(__dirname, "src/renderer"),
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
  },
  build: {
    outDir: path.resolve(root, "dist/renderer"),
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      "@shared": path.resolve(root, "src/shared"),
      "@icons": path.resolve(root, "assets/icons/svg"),
    },
  },
});

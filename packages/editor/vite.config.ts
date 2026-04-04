import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import electron from "vite-plugin-electron";
import path from "path";

const root = path.resolve(__dirname);

export default defineConfig({
  root: path.resolve(__dirname, "src/renderer"),
  plugins: [
    react(),
    electron([
      {
        // Main process
        entry: path.resolve(root, "src/main/index.ts"),
        vite: {
          build: {
            outDir: path.resolve(root, "dist/main"),
            rollupOptions: {
              external: ["electron", "ws"],
            },
          },
        },
        onstart({ startup }) {
          startup([".", "--no-sandbox"]);
        },
      },
      {
        // Preload script
        entry: path.resolve(root, "src/preload/preload.ts"),
        vite: {
          build: {
            outDir: path.resolve(root, "dist/preload"),
            rollupOptions: {
              external: ["electron"],
            },
          },
        },
        onstart({ reload }) {
          reload();
        },
      },
    ]),
  ],
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

import path from "path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@polyflowrobotics/ui-components/style.css": path.resolve(
        __dirname,
        "node_modules/@polyflowrobotics/ui-components/style.css"
      )
    }
  },
  server: {
    port: 5173,
    strictPort: true
  }
});

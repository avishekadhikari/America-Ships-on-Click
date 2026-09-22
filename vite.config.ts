import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import {defineConfig} from 'vite';

// The frontend is a self-contained tree: `frontend/index.html` is the entry and
// everything it imports lives under `frontend/src`. The backend (`backend/`)
// and the database layer (`database/`) are never bundled into the client.
export default defineConfig(() => {
  return {
    root: path.resolve(__dirname, 'frontend'),
    plugins: [react(), tailwindcss()],
    build: {
      // Build out to the repo-root dist/, alongside the bundled server.
      outDir: path.resolve(__dirname, 'dist'),
      emptyOutDir: true,
    },
    // Only VITE_ variables are visible to the browser bundle. Server secrets
    // (JWT, database, payment token, Gemini) stay out of the client.
    envPrefix: 'VITE_',
    resolve: {
      alias: {
        '@': path.resolve(__dirname, 'frontend/src'),
      },
    },
    server: {
      // HMR is disabled in AI Studio via DISABLE_HMR env var.
      // Do not modify—file watching is disabled to prevent flickering during agent edits.
      hmr: process.env.DISABLE_HMR !== 'true',
      // Disable file watching when DISABLE_HMR is true to save CPU during agent edits.
      watch: process.env.DISABLE_HMR === 'true' ? null : {},
    },
  };
});

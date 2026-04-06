import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    port: 5173,
    // WebUSB requires a secure context. localhost counts, so http is fine
    // in dev; if exposing over LAN, set https: true.
  },
  build: {
    target: 'es2022',
  },
});

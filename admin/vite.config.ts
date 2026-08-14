import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  base: '/admin/',
  plugins: [react()],
  server: {
    host: '127.0.0.1',
    port: 43127,
    strictPort: true,
    proxy: {
      '/api': 'http://127.0.0.1:18473',
    },
  },
  preview: {
    host: '127.0.0.1',
    port: 43128,
    strictPort: true,
  },
});

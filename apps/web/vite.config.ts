import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  build: {
    outDir: '../server/public', emptyOutDir: true,
    rollupOptions: { output: { manualChunks: { 'vue-vendor': ['vue'], 'element-plus': ['element-plus'] } } },
  },
  server: { proxy: { '/api': { target: 'http://127.0.0.1:8080', changeOrigin: false } } },
});

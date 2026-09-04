import {defineConfig} from 'vite';
import {resolve} from 'path';

export default defineConfig({
  root: resolve('apps/ios/FamilyArchive/TopolaTreeWeb'),
  base: './',
  plugins: [
    {
      name: 'ios-tree-local-script',
      transformIndexHtml(html: string) {
        // WKWebView can load local file scripts reliably, but blocks ES module
        // subresources from a file:// origin. The Vite output is self-contained.
        return html
          .replace('<script type="module" crossorigin', '<script defer')
          .replace(' crossorigin', '')
      },
    },
  ],
  build: {
    outDir: resolve('apps/ios/FamilyArchive/FamilyArchive/Resources/TopolaTree'),
    emptyOutDir: true,
    rollupOptions: {
      input: resolve('apps/ios/FamilyArchive/TopolaTreeWeb/index.html'),
      output: {
        entryFileNames: 'topola-tree.js',
        chunkFileNames: 'topola-tree-[hash].js',
        assetFileNames: 'topola-tree.[ext]',
      },
    },
  },
});

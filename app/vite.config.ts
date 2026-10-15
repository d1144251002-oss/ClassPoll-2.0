import {defineConfig} from 'vite';
import vue from '@vitejs/plugin-vue';
import {fileURLToPath} from 'node:url';
export default defineConfig({
 root:fileURLToPath(new URL('.',import.meta.url)),
 base:process.env.VITE_BASE_PATH || '/ClassPoll-2.0/app/',
 plugins:[vue()],
 build:{outDir:'dist',emptyOutDir:true,target:'es2022',sourcemap:false},
 server:{port:4173,strictPort:true}
});

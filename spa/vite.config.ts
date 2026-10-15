import {defineConfig} from 'vite';
import vue from '@vitejs/plugin-vue';
export default defineConfig({plugins:[vue()],base:process.env.GITHUB_PAGES ? '/ClassPoll-2.0/spa/' : '/',build:{outDir:'dist',emptyOutDir:true}});

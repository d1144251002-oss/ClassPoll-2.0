import {defineConfig,devices} from '@playwright/test';
export default defineConfig({
 testDir:'./tests',
 timeout:30000,
 retries:process.env.CI?1:0,
 reporter:'list',
 use:{...devices['Desktop Chrome'],baseURL:'http://127.0.0.1:4173/ClassPoll-2.0/app/'},
 webServer:{
  command:'npm run dev -- --host 127.0.0.1',
  url:'http://127.0.0.1:4173/ClassPoll-2.0/app/',
  reuseExistingServer:!process.env.CI,
  timeout:45000
 }
});

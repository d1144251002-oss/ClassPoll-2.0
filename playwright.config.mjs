import {defineConfig,devices} from '@playwright/test';

export default defineConfig({
 testDir:'./tests',
 timeout:30000,
 expect:{timeout:8000},
 fullyParallel:false,
 retries:process.env.CI?1:0,
 reporter:'list',
 use:{
   ...devices['Desktop Chrome'],
   baseURL:'http://127.0.0.1:8000',
   trace:'retain-on-failure'
 },
 webServer:{
   command:'python3 -m http.server 8000 --bind 127.0.0.1',
   url:'http://127.0.0.1:8000',
   reuseExistingServer:!process.env.CI,
   timeout:30000
 }
});

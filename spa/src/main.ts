import {createApp} from 'vue';
import App from './App.vue';
import {router} from './router';
import {initializeSession} from './auth';
import './style.css';

const app=createApp(App);
app.use(router);
void initializeSession().catch(e=>console.error('校園身分初始化失敗',e)).finally(()=>{
 app.mount('#app');
 if(import.meta.env.PROD && 'serviceWorker' in navigator){
  navigator.serviceWorker.register(import.meta.env.BASE_URL+'sw.js')
   .catch(e=>console.warn('PWA 註冊失敗',e));
 }
});

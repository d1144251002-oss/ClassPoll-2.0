import {createApp} from 'vue';
import App from './App.vue';
import {router} from './router';
import {initializeSession} from './auth';
import './style.css';
const app=createApp(App);
app.use(router);
void initializeSession().catch(e=>console.error('校園身分初始化失敗',e)).finally(()=>app.mount('#app'));

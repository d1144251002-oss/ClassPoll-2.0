<script setup lang="ts">
import {ref} from 'vue';
import {useRouter} from 'vue-router';
import {configured,loginTeacher} from '../auth';
const router=useRouter();
const email=ref(''),password=ref(''),pending=ref(false),message=ref('');
async function submit(){
 pending.value=true;message.value='';
 try{await loginTeacher(email.value,password.value);password.value='';await router.replace('/dashboard');}
 catch(e){message.value=e instanceof Error?e.message:'驗證失敗';}
 finally{pending.value=false;password.value='';}
}
</script>
<template><section class="panel login">
 <p style="color:#257c88;font-weight:700">LUNG HWA UNIVERSITY OF SCIENCE AND TECHNOLOGY</p>
 <h1>ClassPoll 3.0 管理工作台</h1><p class="muted">此為 SPA 架構開發版。正式教學仍由 ClassPoll 2.0 服務。</p>
 <p v-if="!configured" class="danger" role="alert">尚未設定 Supabase 公開 URL／Publishable Key。</p>
 <form class="form" @submit.prevent="submit">
  <label>教師 Email <input v-model="email" type="email" autocomplete="username" required></label>
  <label>登入密碼 <input v-model="password" type="password" autocomplete="current-password" required></label>
  <button class="primary" type="submit" :disabled="pending||!configured">{{pending?'驗證中…':'登入工作台'}}</button>
  <p v-if="message" class="error" role="alert">{{message}}</p>
 </form>
 <p class="muted">學生端、校方 SSO 尚未遷移至本 SPA；請使用現有正式網站。</p>
 </section></template>

<script setup lang="ts">
import {computed} from 'vue';
import {RouterLink,RouterView,useRouter} from 'vue-router';
import {currentUser,initializing,role,logout} from './auth';
const router=useRouter();
const modules=[{path:'/dashboard',label:'營運儀表板'},{path:'/rooms',label:'教室與學生管理'},{path:'/classes',label:'學期與課程'},{path:'/grades',label:'教學與成績'},{path:'/announcements',label:'校園通知'},{path:'/system',label:'維運與資安'}];
const showNav=computed(()=>!initializing.value&&role.value==='teacher');
async function signOut(){try{await logout();await router.replace('/login');}catch(e){alert(e instanceof Error?e.message:'登出失敗');}}
</script>
<template>
<div v-if="initializing" class="panel login" role="status">正在確認校園工作階段…</div>
<div v-else-if="showNav" class="shell">
 <aside class="sidebar">
  <div class="brand"><small>龍華科技大學</small><strong>ClassPoll 3.0</strong><small>校園教學管理平台</small></div>
  <nav class="nav" aria-label="主選單"><RouterLink v-for="item in modules" :key="item.path" :to="item.path">{{item.label}}</RouterLink></nav>
  <div style="overflow-wrap:anywhere;font-size:12px;color:#c4dced">{{currentUser?.email}}</div>
  <button class="secondary" @click="signOut">登出工作台</button>
 </aside>
 <main class="page"><RouterView/></main>
</div>
<main v-else class="page"><RouterView/></main>
</template>

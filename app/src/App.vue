<script setup lang="ts">
import {computed,onMounted,ref,watch} from 'vue';
import {useRouter,RouterView,RouterLink} from 'vue-router';
import {session,restoreSession,signInTeacher,signInStudent,signOut} from './services/session';

const router=useRouter(),mode=ref<'teacher'|'student'>('teacher'),drawer=ref(false);
const email=ref(''),password=ref(''),roomCode=ref(''),studentNo=ref(''),accessCode=ref('');
const loggingOut=ref(false);
const nav=computed(()=>{
 const base=[
 {to:'/dashboard',icon:'▦',name:'總覽'},
 {to:'/courses',icon:'▤',name:'學期與課程'},
 {to:'/assignments',icon:'✎',name:'作業與繳交'},
 {to:'/notices',icon:'◈',name:'校園公告'}
 ];
 if(session.role==='student')return base;
 return [
  ...base.slice(0,2),
  {to:'/people',icon:'♙',name:'人員與修課'},
  ...base.slice(2),
  {to:'/grades',icon:'▥',name:'成績與覆核'},
  {to:'/security',icon:'⚙',name:'角色與安全'}
 ];
});
watch(()=>router.currentRoute.value.fullPath,()=>drawer.value=false);
onMounted(async()=>{
 const params=new URLSearchParams(location.search);
 if(params.get('room')){mode.value='student';roomCode.value=params.get('room')||''}
 await restoreSession();
});
async function loginTeacher(){
 try{await signInTeacher(email.value,password.value);password.value='';await router.push('/dashboard')}
 catch{/* Error provided by shared store */}
}
async function loginStudent(){
 try{await signInStudent(roomCode.value,studentNo.value,accessCode.value);accessCode.value='';await router.push('/dashboard')}
 catch{/* Error provided by shared store */}
}
async function logout(){
 loggingOut.value=true;
 try{await signOut();await router.push('/dashboard')}
 catch(e){console.warn('遠端登出請再確認工作階段',e)}
 finally{loggingOut.value=false;drawer.value=false;password.value='';accessCode.value=''}
}
</script>
<template>
 <div v-if="!session.ready" class="center-load" role="status">正在載入 ClassPoll 校園平台…</div>
 <div v-else-if="!session.role" class="public-layout">
  <header class="campus-brand"><span class="brand-monogram">龍</span><span><b>龍華科技大學</b><small>LUNGHWA UNIVERSITY OF SCIENCE AND TECHNOLOGY</small></span></header>
  <main class="login-body">
   <div class="login-copy">
    <span class="eyebrow">CLASSROOM OPERATIONS · V3</span>
    <h1>教學、課務與分析，<em>真正整合在同一個平台。</em></h1>
    <p>學期課程、師生名冊、作業批改、成績覆核、公告與資訊安全，採同一套 Vue 工作台，不再透過 iframe 切換。</p>
    <div class="login-highlights"><span>課程與角色授權</span><span>出席及成績管理</span><span>私有公告通知</span></div>
   </div>
   <section class="login-card" aria-labelledby="login-title">
    <span class="eyebrow">SECURE CAMPUS ACCESS</span><h2 id="login-title">登入校園系統</h2>
    <div class="login-tabs" role="group" aria-label="使用身分">
     <button type="button" :class="{selected:mode==='teacher'}" @click="mode='teacher'">教師／行政人員</button>
     <button type="button" :class="{selected:mode==='student'}" @click="mode='student'">學生</button>
    </div>
    <p v-if="session.error" class="alert error" role="alert">{{session.error}}</p>
    <form v-if="mode==='teacher'" class="stack" @submit.prevent="loginTeacher">
     <label>電子郵件<input v-model.trim="email" type="email" autocomplete="username" required placeholder="教師或行政人員電子郵件"/></label>
     <label>密碼<input v-model="password" type="password" autocomplete="current-password" required/></label>
     <button class="primary" :disabled="session.busy" type="submit">{{session.busy?'驗證中…':'登入校園管理'}}</button>
     <p class="tiny-note">教職員須經授權，校級管理者必須由資料庫管理員核准設置。</p>
    </form>
    <form v-else class="stack" @submit.prevent="loginStudent">
     <label>教室代碼<input v-model.trim="roomCode" required maxlength="12" autocomplete="off"/></label>
     <label>學號<input v-model.trim="studentNo" required maxlength="40" autocomplete="off"/></label>
     <label>個人入班碼<input v-model="accessCode" type="password" autocomplete="off" required/></label>
     <button class="primary" :disabled="session.busy" type="submit">{{session.busy?'核對名冊中…':'進入我的課堂'}}</button>
     <p class="tiny-note">學生資格依現有教室名冊驗證；校方 SSO 尚需正式身分供應商介接。</p>
    </form>
   </section>
  </main>
 </div>
 <div v-else class="app-layout">
  <aside class="sidebar" :class="{open:drawer}" aria-label="主要功能選單">
   <div class="brand-block"><strong>龍華科技大學</strong><span>ClassPoll 3.0</span><small>校園教學管理平台</small></div>
   <nav>
    <RouterLink v-for="item in nav" :key="item.to" :to="item.to" @click="drawer=false">
     <span aria-hidden="true">{{item.icon}}</span>{{item.name}}
    </RouterLink>
   </nav>
   <div class="legacy-nav">
    <p>既有教學功能</p>
    <a v-if="session.role==='teacher'" href="../teacher.html" target="_blank" rel="noopener noreferrer">原有即時測驗 ↗</a>
    <a v-else href="../student.html" target="_blank" rel="noopener noreferrer">原有課堂作答 ↗</a>
    <a v-if="session.role==='teacher'" href="../ballots.html" target="_blank" rel="noopener noreferrer">校園表決模組 ↗</a>
    <a v-else href="../vote.html" target="_blank" rel="noopener noreferrer">校園表決入口 ↗</a>
   </div>
   <div class="identity"><small>已驗證身分 · {{session.staffRole}}</small><strong>{{session.identity}}</strong><button type="button" @click="logout" :disabled="loggingOut">登出平台 ↗</button></div>
  </aside>
  <button type="button" v-if="drawer" class="mobile-backdrop" aria-label="關閉選單" @click="drawer=false"></button>
  <div class="main-area">
   <header class="app-top"><button type="button" class="hamburger" @click="drawer=!drawer" aria-label="開關選單">☰</button><div><small>龍華科技大學 / ClassPoll</small><b>整合校園工作台</b></div><span class="live-indicator">● 已連線</span></header>
   <main class="view-container">
    <div v-if="session.error" class="alert error" role="alert">{{session.error}}</div>
    <div v-if="session.message" class="alert success" role="status">{{session.message}} <button type="button" @click="session.message=''">關閉</button></div>
    <RouterView :key="session.role" />
   </main>
  </div>
 </div>
</template>

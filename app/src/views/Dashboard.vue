<script setup lang="ts">
import {onMounted,ref,computed} from 'vue';
import {RouterLink} from 'vue-router';
import {db,rpc,typedError} from '../services/api';
import {session} from '../services/session';
type Entry={id:string;code:string;title:string;status:string;year:number;semester:number;students:number};
const records=ref<Entry[]>([]),unread=ref(0),error=ref(''),loading=ref(false);
const active=computed(()=>records.value.filter(x=>x.status==='active'));
const participants=computed(()=>active.value.reduce((n,x)=>n+(Number(x.students)||0),0));
async function refresh(){
 loading.value=true;error.value='';
 try{const info=await rpc<{courses:Entry[];unread:number}>(db(),'cp3_dashboard');
  records.value=info.courses||[];unread.value=Number(info.unread)||0;
 }catch(e){error.value=typedError(e)}finally{loading.value=false}
}
onMounted(refresh);
</script>
<template>
 <section class="page-heading"><div><span class="eyebrow">CAMPUS OVERVIEW</span><h1>{{session.role==='student'?'我的學習儀表板':'校園教學儀表板'}}</h1><p class="muted">資料由受權限管制的資料庫即時查詢，不顯示未授權的課程。</p></div><button class="outline" :disabled="loading" @click="refresh">↻ 更新資料</button></section>
 <div v-if="error" class="alert error">{{error}}</div>
 <div class="cards">
  <div class="card"><small>目前可存取課程</small><span class="number">{{active.length}}</span><small>依登入身分授權</small></div>
  <div class="card"><small>課程總計（含封存）</small><span class="number">{{records.length}}</span><small>不含無權讀取的課程</small></div>
  <div class="card"><small>待讀公告</small><span class="number">{{unread}}</span><small>本人的公告通知</small></div>
  <div class="card"><small>{{session.role==='student'?'登入狀態':'課程修課人次'}}</small><span class="number">{{session.role==='student'?'✓':participants}}</span><small>{{session.role==='student'?'已通過名冊核驗':'各課程名冊加總'}}</small></div>
 </div>
 <div class="grid-2" style="margin-top:20px">
  <section class="panel"><div class="flex-space"><h2>我的課程</h2><RouterLink to="/courses">全部課程 ↗</RouterLink></div>
   <div v-if="!records.length" class="empty">目前還沒有學期課程。既有教室與課堂內容仍可在原系統使用。</div>
   <div v-for="course in records.slice(0,8)" :key="course.id" class="list-row">
    <div><strong>{{course.code}} · {{course.title}}</strong><div class="small muted">{{course.year}} 學年度 / 第 {{course.semester}} 學期</div></div>
    <span :class="['chip',{'inactive':course.status==='archived'}]">{{course.status==='active'?'進行中':'已封存'}}</span>
   </div>
  </section>
  <section class="panel"><h2>常用操作</h2><div class="grid-gap">
   <RouterLink class="outline" to="/assignments">查看作業及繳交 →</RouterLink>
   <RouterLink class="outline" to="/notices">開啟公告通知 →</RouterLink>
   <RouterLink v-if="session.role==='teacher'" class="outline" to="/people">管理人員及修課名冊 →</RouterLink>
   <RouterLink v-if="session.role==='teacher'" class="outline" to="/grades">核對成績簿 →</RouterLink>
  </div></section>
 </div>
</template>

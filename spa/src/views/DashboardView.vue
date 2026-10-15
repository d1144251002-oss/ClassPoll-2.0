<script setup lang="ts">
import {onMounted,ref} from 'vue';
import {supabase} from '../auth';
import {RouterLink} from 'vue-router';
interface Metrics {room_count:number;students:number;present_today:number;recent_errors:number}
const metrics=ref<Metrics>({room_count:0,students:0,present_today:0,recent_errors:0});
const loading=ref(true),error=ref('');
async function refresh(){
 if(!supabase){loading.value=false;return;}
 loading.value=true;error.value='';
 try{
  const {data,error:e}=await supabase.rpc('cp2_platform_overview');if(e)throw e;
  const rooms=Array.isArray(data?.rooms)?data.rooms as Record<string,unknown>[]:[];
  metrics.value={
   room_count:rooms.length,
   students:rooms.reduce((n,r)=>n+Number(r.active_students??0),0),
   present_today:rooms.reduce((n,r)=>n+Number(r.present_today??0),0),
   recent_errors:rooms.reduce((n,r)=>n+Number(r.recent_errors??0),0)
  };
 }catch(e){error.value=e instanceof Error?e.message:'管理資訊載入失敗';}
 finally{loading.value=false;}
}
onMounted(refresh);
</script>
<template>
 <div class="bar"><div><p class="muted">龍華科技大學 / 教學管理</p><h1>校園營運儀表板</h1></div><button class="secondary" @click="refresh">重新整理</button></div>
 <p v-if="error" class="error" role="alert">{{error}}</p><p v-if="loading">載入統計中…</p>
 <div class="stats">
  <article class="stat"><small>可管理教室</small><strong>{{metrics.room_count}}</strong></article>
  <article class="stat"><small>有效學生</small><strong>{{metrics.students}}</strong></article>
  <article class="stat"><small>今日出席</small><strong>{{metrics.present_today}}</strong></article>
  <article class="stat"><small>近期錯誤</small><strong>{{metrics.recent_errors}}</strong></article>
 </div>
 <div class="grid">
  <section class="panel"><h2>教室與學生管理</h2><p class="muted">教室封存、學生停用與恢復操作保留歷史資料及稽核。</p><RouterLink to="/rooms">進入管理 →</RouterLink></section>
  <section class="panel"><h2>架構升級狀態</h2><p class="muted">SPA 目前先承接教師總覽及課程生命週期。尚未切換整個正式網站。</p></section>
 </div>
</template>

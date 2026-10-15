<script setup lang="ts">
import {onMounted,ref} from 'vue';
import {supabase} from '../auth';
interface Room {room_id:string;room_code:string;room_title:string}
interface Notice {id:string;title:string;body:string;published_at:string;is_read:boolean}
const rooms=ref<Room[]>([]),roomId=ref(''),notices=ref<Notice[]>([]);
const title=ref(''),body=ref(''),pending=ref(false),error=ref(''),message=ref('');
async function initialize(){
 if(!supabase)return;
 const {data,error:e}=await supabase.rpc('cp3_course_list');
 if(e){error.value=e.message;return;}
 rooms.value=(data??[]) as Room[];
 roomId.value=rooms.value[0]?.room_id??'';
 await refresh();
}
async function refresh(){
 if(!supabase||!roomId.value)return;
 error.value='';
 const {data,error:e}=await supabase.rpc('cp3_notice_list',{p_room:roomId.value});
 if(e){error.value=e.message;return;}
 notices.value=(data??[]) as Notice[];
}
async function publish(){
 if(!supabase||pending.value||!roomId.value)return;
 if(!title.value.trim()||!body.value.trim())return;
 pending.value=true;error.value='';message.value='';
 try{
  const {error:e}=await supabase.rpc('cp3_post_notice',{p_room:roomId.value,p_title:title.value,p_body:body.value});
  if(e)throw e;
  title.value='';body.value='';message.value='公告已發布，已記錄稽核紀錄。';
  await refresh();
 }catch(e){error.value=e instanceof Error?e.message:'發布失敗';}
 finally{pending.value=false;}
}
onMounted(initialize);
</script>
<template>
 <div class="bar"><div><p class="muted">龍華科技大學 / 校園通知</p><h1>教師公告中心</h1></div><button class="secondary" @click="refresh">重新整理</button></div>
 <p v-if="error" class="error" role="alert">{{error}}</p><p v-if="message" role="status">{{message}}</p>
 <div class="grid"><section class="panel">
  <h2>發布課堂公告</h2>
  <form class="form" @submit.prevent="publish">
   <label>所屬課堂<select v-model="roomId" @change="refresh"><option v-for="r in rooms" :key="r.room_id" :value="r.room_id">{{r.room_title}} · {{r.room_code}}</option></select></label>
   <label>標題<input v-model="title" maxlength="160" required></label>
   <label>公告內容<textarea v-model="body" rows="6" maxlength="10000" required></textarea></label>
   <button class="primary" type="submit" :disabled="pending||!roomId">{{pending?'發布中…':'發布公告'}}</button>
  </form>
  <p class="muted">只有教室擁有者可以發布；所有內容由後端角色與教室權限驗證。</p>
 </section>
 <section class="panel"><h2>最近公告</h2>
  <div class="card-list">
   <article v-for="item in notices" :key="item.id">
    <strong>{{item.title}}</strong><small class="muted" style="display:block">{{new Date(item.published_at).toLocaleString('zh-TW')}}</small>
    <p>{{item.body}}</p>
   </article>
   <p v-if="!notices.length" class="muted">尚無公告。</p>
  </div>
 </section></div>
</template>
<style scoped>select,textarea{width:100%;padding:10px;border:1px solid #cad7e4;border-radius:8px;font:inherit}article{border-bottom:1px solid #e6edf3;padding:12px 0}article p{white-space:pre-wrap;overflow-wrap:anywhere}</style>

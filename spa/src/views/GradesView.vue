<script setup lang="ts">
import {computed,onMounted,ref} from 'vue';
import {supabase} from '../auth';
interface Room {room_id:string;room_title:string;room_code:string}
const rooms=ref<Room[]>([]),roomId=ref(''),attendance=ref(20),quizzes=ref(80),assignments=ref(0);
const total=computed(()=>Number(attendance.value)+Number(quizzes.value)+Number(assignments.value));
const pending=ref(false),message=ref(''),error=ref('');
async function init(){
 if(!supabase)return;
 const {data,error:e}=await supabase.rpc('cp3_course_list');
 if(e){error.value=e.message;return;}
 rooms.value=(data??[]) as Room[];roomId.value=rooms.value[0]?.room_id??'';
 await load();
}
async function load(){
 if(!supabase||!roomId.value)return;error.value='';message.value='';
 const {data,error:e}=await supabase.rpc('cp3_get_grade_weights',{p_room:roomId.value});
 if(e){error.value=e.message;return;}
 attendance.value=Number(data?.attendance??20);
 quizzes.value=Number(data?.quizzes??80);
 assignments.value=Number(data?.assignments??0);
}
async function save(){
 if(!supabase||pending.value)return;
 if(total.value!==100||[attendance.value,quizzes.value,assignments.value].some(x=>x<0||x>100||!Number.isFinite(x))){error.value='權重必須均在 0～100 且總計 100%';return;}
 pending.value=true;error.value='';message.value='';
 try{
  const {error:e}=await supabase.rpc('cp3_set_grade_weights',{
   p_room:roomId.value,p_attendance:attendance.value,p_quizzes:quizzes.value,p_assignments:assignments.value
  });
  if(e)throw e;
  message.value='權重已儲存，並寫入教室操作稽核。';
 }catch(e){error.value=e instanceof Error?e.message:'儲存失敗';}
 finally{pending.value=false;}
}
onMounted(init);
</script>
<template>
 <div class="bar"><div><p class="muted">龍華科技大學 / 學習成績管理</p><h1>課程成績權重設定</h1></div></div>
 <p class="muted">此設定是成績管理的基礎，**尚不會自動改寫正式成績，也不會送到校務系統**。正式成績必須經教師覆核與簽核。</p>
 <section class="panel" style="max-width:620px">
  <form class="form" @submit.prevent="save">
   <label>課程<select v-model="roomId" @change="load"><option v-for="r in rooms" :key="r.room_id" :value="r.room_id">{{r.room_title}} · {{r.room_code}}</option></select></label>
   <label>出席比例（%）<input v-model.number="attendance" type="number" min="0" max="100" step="0.01"></label>
   <label>測驗比例（%）<input v-model.number="quizzes" type="number" min="0" max="100" step="0.01"></label>
   <label>作業比例（%）<input v-model.number="assignments" type="number" min="0" max="100" step="0.01"></label>
   <p :class="total===100?'muted':'error'">目前加總：<strong>{{total}}%</strong>（必須等於 100%）</p>
   <p v-if="error" role="alert" class="error">{{error}}</p><p v-if="message" role="status">{{message}}</p>
   <button type="submit" class="primary" :disabled="pending||total!==100||!roomId">{{pending?'儲存中…':'儲存成績權重'}}</button>
  </form>
 </section>
</template>
<style scoped>select{width:100%;padding:10px;border:1px solid #cad7e4;border-radius:8px;font:inherit}</style>

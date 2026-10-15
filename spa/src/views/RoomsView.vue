<script setup lang="ts">
import {onMounted,ref} from 'vue';
import {supabase} from '../auth';
interface Room {room_id:string;room_code:string;room_title:string;course_id:string|null;archived_at:string|null;students:number;department_code:string|null;academic_year:string|null;term:number|null}
interface Student{id:string;student_no:string;display_name:string;is_active:boolean}
const rooms=ref<Room[]>([]),students=ref<Student[]>([]),selected=ref<Room|null>(null);
const loading=ref(false),busy=ref(false),message=ref(''),error=ref('');
async function refresh(){
 if(!supabase)return;
 loading.value=true;error.value='';
 try{
  const {data,error:e}=await supabase.rpc('cp3_course_list');if(e)throw e;
  rooms.value=(data??[]) as Room[];
  if(selected.value)selected.value=rooms.value.find(r=>r.room_id===selected.value?.room_id)??null;
  if(selected.value)await loadStudents(selected.value);
 }catch(e){error.value=e instanceof Error?e.message:'教室載入失敗';}
 finally{loading.value=false;}
}
async function loadStudents(room:Room){
 if(!supabase)return;selected.value=room;students.value=[];error.value='';
 const {data,error:e}=await supabase.from('cp2_students').select('id,student_no,display_name,is_active').eq('room_id',room.room_id).order('student_no');
 if(e)error.value=e.message;else students.value=(data??[]) as Student[];
}
async function archive(room:Room){
 if(!supabase||busy.value)return;
 const going=!room.archived_at;
 if(!confirm(going?'封存課程並停用教室？不會刪除歷史成績。':'重新開放教室？'))return;
 busy.value=true;error.value='';
 try{const {error:e}=await supabase.rpc('cp3_archive_course',{p_room:room.room_id,p_archived:going});if(e)throw e;message.value='課程狀態已更新';await refresh();}
 catch(e){error.value=e instanceof Error?e.message:'更新失敗';}
 finally{busy.value=false;}
}
async function setStudent(s:Student){
 if(!supabase||busy.value)return;
 const disabling=s.is_active;
 if(!confirm(disabling?'停用這位學生？歷史出席與成績將保留。':'恢復這位學生的入班資格？'))return;
 busy.value=true;error.value='';
 try{
  const {error:e}=await supabase.rpc('cp3_manage_student',{p_student:s.id,p_action:disabling?'disable':'restore',p_reason:'校園教務管理'});
  if(e)throw e;
  message.value='學生狀態已更新';
  if(selected.value)await loadStudents(selected.value);
 }catch(e){error.value=e instanceof Error?e.message:'更新失敗';}
 finally{busy.value=false;}
}
onMounted(refresh);
</script>
<template>
 <div class="bar"><div><p class="muted">龍華科技大學 / 學期課程管理</p><h1>教室與學生</h1></div><button class="secondary" @click="refresh">重新同步</button></div>
 <p v-if="message" role="status">{{message}}</p><p v-if="error" class="error" role="alert">{{error}}</p>
 <p class="muted">學生「刪除」採安全停用；課程「刪除」採封存，保留原有學習歷史。永久刪除須由資料治理程序核准。</p>
 <section class="panel">
  <p v-if="loading">讀取課程中…</p>
  <div class="tablewrap"><table class="table"><thead><tr><th>教室代碼</th><th>名稱</th><th>學生</th><th>狀態</th><th>操作</th></tr></thead><tbody>
   <tr v-for="room in rooms" :key="room.room_id"><td>{{room.room_code}}</td><td>{{room.room_title}}</td><td>{{room.students}}</td><td>{{room.archived_at?'已封存':'使用中'}}</td><td><div class="inline"><button class="secondary" @click="loadStudents(room)">查看學生</button><button class="secondary" :disabled="busy" @click="archive(room)">{{room.archived_at?'復原課程':'封存課程'}}</button></div></td></tr>
   <tr v-if="rooms.length===0"><td colspan="5">目前沒有可管理的教室，或新版資料庫尚未啟用。</td></tr>
  </tbody></table></div>
 </section>
 <section v-if="selected" class="panel" style="margin-top:20px">
 <h2>{{selected.room_title}} — 學生名冊</h2>
 <div class="tablewrap"><table class="table"><thead><tr><th>學號</th><th>學生</th><th>狀態</th><th>安全操作</th></tr></thead><tbody>
  <tr v-for="student in students" :key="student.id"><td>{{student.student_no}}</td><td>{{student.display_name}}</td><td>{{student.is_active?'有效':'已停用'}}</td><td><button class="secondary" :disabled="busy" @click="setStudent(student)">{{student.is_active?'停用':'復原'}}</button></td></tr>
 </tbody></table></div>
 </section>
</template>

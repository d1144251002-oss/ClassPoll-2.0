<script setup lang="ts">
import {onMounted,ref} from 'vue';
import {supabase,currentUser} from '../auth';
interface Room {room_id:string;room_code:string;room_title:string;course_id:string|null;archived_at:string|null;students:number;department_code:string|null;academic_year:string|null;term:number|null}
interface Student{id:string;student_no:string;display_name:string;is_active:boolean}
const rooms=ref<Room[]>([]),students=ref<Student[]>([]),selected=ref<Room|null>(null);
const loading=ref(false),busy=ref(false),message=ref(''),error=ref('');
const newRoomCode=ref(''),newRoomName=ref(''),studentNumber=ref(''),studentName=ref(''),lastCode=ref<{name:string;number:string;secret:string}|null>(null);
async function createRoom(){
 if(!supabase||!currentUser.value||busy.value)return;
 const code=newRoomCode.value.trim().toUpperCase(),title=newRoomName.value.trim();
 if(!/^[A-Z0-9]{4,12}$/.test(code)||title.length<1||title.length>100){error.value='教室代碼需為 4～12 個英數字，名稱需介於 1～100 字';return;}
 busy.value=true;error.value='';message.value='';
 try{
  const {error:e}=await supabase.from('cp2_rooms').insert({code,title,owner_id:currentUser.value.id});
  if(e)throw e;
  newRoomCode.value='';newRoomName.value='';message.value='教室已建立';
  await refresh();
 }catch(e){error.value=e instanceof Error?e.message:'新增教室失敗';}
 finally{busy.value=false;}
}
async function createStudent(){
 if(!supabase||busy.value||!selected.value)return;
 const number=studentNumber.value.trim(),name=studentName.value.trim();
 if(number.length<1||number.length>40||name.length<1||name.length>80){error.value='學號與姓名不符合長度限制';return;}
 busy.value=true;lastCode.value=null;error.value='';message.value='';
 try{
  const {data,error:e}=await supabase.rpc('cp2_add_student',{p_room:selected.value.room_id,p_number:number,p_name:name});
  if(e)throw e;
  const record=Array.isArray(data)?data[0]:null;
  if(!record?.access_code)throw Error('伺服器未返回新入班碼；請先刷新名冊避免重複新增');
  lastCode.value={name,number,secret:String(record.access_code)};
  studentNumber.value='';studentName.value='';message.value='學生已新增，請立即將個人入班碼安全交付本人';
  await loadStudents(selected.value);
 }catch(e){error.value=e instanceof Error?e.message:'新增學生失敗';}
 finally{busy.value=false;}
}
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
 if(!supabase)return;selected.value=room;students.value=[];lastCode.value=null;error.value='';
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
 <section class="panel" style="margin-bottom:20px">
  <h2>新增教室</h2>
  <form class="form" @submit.prevent="createRoom">
   <label>教室代碼（4～12 碼英數字）<input v-model="newRoomCode" maxlength="12" required placeholder="LHU2026A"></label>
   <label>教室名稱<input v-model="newRoomName" maxlength="100" required placeholder="程式設計（一）"></label>
   <button type="submit" class="primary" :disabled="busy">新增教室</button>
  </form>
 </section>
 <section class="panel">
  <p v-if="loading">讀取課程中…</p>
  <div class="tablewrap"><table class="table"><thead><tr><th>教室代碼</th><th>名稱</th><th>學生</th><th>狀態</th><th>操作</th></tr></thead><tbody>
   <tr v-for="room in rooms" :key="room.room_id"><td>{{room.room_code}}</td><td>{{room.room_title}}</td><td>{{room.students}}</td><td>{{room.archived_at?'已封存':'使用中'}}</td><td><div class="inline"><button class="secondary" @click="loadStudents(room)">查看學生</button><button class="secondary" :disabled="busy" @click="archive(room)">{{room.archived_at?'復原課程':'封存課程'}}</button></div></td></tr>
   <tr v-if="rooms.length===0"><td colspan="5">目前沒有可管理的教室，或新版資料庫尚未啟用。</td></tr>
  </tbody></table></div>
 </section>
 <section v-if="selected" class="panel" style="margin-top:20px">
 <h2>{{selected.room_title}} — 學生名冊</h2>
 <form class="form" style="max-width:540px;margin-bottom:16px" @submit.prevent="createStudent">
  <label>學生學號<input v-model="studentNumber" maxlength="40" required></label>
  <label>學生姓名<input v-model="studentName" maxlength="80" required></label>
  <button type="submit" class="primary" :disabled="busy">新增學生並產生入班碼</button>
 </form>
 <div v-if="lastCode" class="danger" role="status">
  <strong>一次性入班碼：{{lastCode.secret}}</strong>
  <p>{{lastCode.name}}（{{lastCode.number}}）請立即安全保存；登出後不會再次顯示。</p>
  <button class="secondary" type="button" @click="lastCode=null">已完成交付，清除此畫面</button>
 </div>
 <div class="tablewrap"><table class="table"><thead><tr><th>學號</th><th>學生</th><th>狀態</th><th>安全操作</th></tr></thead><tbody>
  <tr v-for="student in students" :key="student.id"><td>{{student.student_no}}</td><td>{{student.display_name}}</td><td>{{student.is_active?'有效':'已停用'}}</td><td><button class="secondary" :disabled="busy" @click="setStudent(student)">{{student.is_active?'停用':'復原'}}</button></td></tr>
 </tbody></table></div>
 </section>
</template>

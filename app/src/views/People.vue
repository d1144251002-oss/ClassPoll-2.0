<script setup lang="ts">
import {onMounted,ref,watch,computed} from 'vue';
import {db,rpc,typedError} from '../services/api';
import {flash} from '../services/session';
type Student={id:string;room_id:string;student_no:string;display_name:string;is_active:boolean};
type Room={id:string;title:string;code:string};
type Course={id:string;room_id:string;title:string;status:string};
const rooms=ref<Room[]>([]),students=ref<Student[]>([]),courses=ref<Course[]>([]);
const roomId=ref(''),courseId=ref(''),selectedStudent=ref(''),studentNo=ref(''),studentName=ref('');
const error=ref(''),issuedCode=ref(''),loading=ref(false);
const roster=computed(()=>students.value.filter(s=>s.room_id===roomId.value));
const activeCourses=computed(()=>courses.value.filter(c=>c.status==='active' && c.room_id===roomId.value));
async function load(){
 loading.value=true;error.value='';
 try{
  const {data,error:err}=await db().from('cp2_rooms').select('id,title,code').order('created_at',{ascending:false});
  if(err)throw err;
  rooms.value=(data||[]) as Room[];
  courses.value=await rpc<Course[]>(db(),'cp3_course_list');
  if(!rooms.value.some(x=>x.id===roomId.value))roomId.value=rooms.value[0]?.id||'';
  await loadRoster();
 }catch(e){error.value=typedError(e)}finally{loading.value=false}
}
async function loadRoster(){
 students.value=[];if(!roomId.value)return;
 try{
  const {data,error:err}=await db().from('cp2_students').select('id,room_id,student_no,display_name,is_active')
    .eq('room_id',roomId.value).order('student_no');
  if(err)throw err;students.value=(data||[]) as Student[];
 }catch(e){error.value=typedError(e)}
}
watch(roomId,async()=>{issuedCode.value='';courseId.value='';await loadRoster()});
async function add(){
 try{
  const rows=await rpc<Array<{access_code:string}>>(db(),'cp2_add_student',{p_room:roomId.value,p_number:studentNo.value,p_name:studentName.value});
  if(!rows?.[0]?.access_code)throw Error('未取得一次性入班碼');
  issuedCode.value=rows[0].access_code;
  studentNo.value='';studentName.value='';
  flash('學生已新增。請立即安全保存入班碼');await loadRoster();
 }catch(e){error.value=typedError(e)}
}
async function change(s:Student){
 if(!confirm((s.is_active?'停用':'恢復')+'學生 '+s.display_name+'？停用後不能繼續以此名冊身分作答，但不刪除歷史紀錄。'))return;
 try{await rpc(db(),'cp3_student_set_active',{p_student:s.id,p_active:!s.is_active});flash('學生狀態已更新');await loadRoster()}
 catch(e){error.value=typedError(e)}
}
async function enroll(){
 if(!courseId.value||!selectedStudent.value)return;
 try{await rpc(db(),'cp3_course_enroll',{p_course:courseId.value,p_student:selectedStudent.value,p_active:true});flash('學生已加入課程')}
 catch(e){error.value=typedError(e)}
}
onMounted(load);
</script>
<template>
 <div class="page-heading"><div><span class="eyebrow">PEOPLE & ROSTER</span><h1>學生名冊與修課管理</h1><p class="muted">新增學生、停用／恢復帳號及修課登記。保留正式出席和成績歷史，不提供危險的直接刪除。</p></div><button class="outline" @click="load" :disabled="loading">重新整理</button></div>
 <div v-if="error" class="alert error" role="alert">{{error}}</div>
 <div class="grid-2" style="margin-bottom:18px">
  <form class="panel stack" @submit.prevent="add"><h2>新增學生</h2>
   <label>教室<select v-model="roomId" required><option v-for="room in rooms" :key="room.id" :value="room.id">{{room.title}}（{{room.code}}）</option></select></label>
   <div class="grid-2"><label>學號<input v-model.trim="studentNo" maxlength="40" required/></label><label>姓名<input v-model.trim="studentName" maxlength="80" required/></label></div>
   <button class="primary" type="submit" :disabled="!roomId">新增至名冊</button>
   <div v-if="issuedCode" class="alert success"><b>新發放入班碼：</b><code>{{issuedCode}}</code><div class="small">請即刻交付學生。離開頁面後不再顯示，不能以此頁重新查出。</div><button type="button" class="outline" @click="issuedCode=''">已保存，清除畫面</button></div>
  </form>
  <form class="panel stack" @submit.prevent="enroll"><h2>修課登記</h2><p class="muted">學生必須先存在對應教室的名冊中，才能選修此課程。</p>
   <label>開課課程<select v-model="courseId" required><option value="" disabled>選擇課程</option><option v-for="c in activeCourses" :key="c.id" :value="c.id">{{c.title}}</option></select></label>
   <label>學生<select v-model="selectedStudent" required><option value="" disabled>選擇學生</option><option v-for="s in roster.filter(x=>x.is_active)" :key="s.id" :value="s.id">{{s.student_no}} · {{s.display_name}}</option></select></label>
   <button class="primary" type="submit" :disabled="!courseId||!selectedStudent">加入課程</button>
  </form>
 </div>
 <section class="panel"><div class="flex-space"><h2>教室學生（{{roster.length}}）</h2><span class="chip">{{rooms.find(x=>x.id===roomId)?.title||'未選擇教室'}}</span></div>
  <div v-if="!roster.length" class="empty">此教室尚未建立學生名冊。</div>
  <div v-else class="table-wrap"><table><thead><tr><th>學號</th><th>學生姓名</th><th>狀態</th><th>操作</th></tr></thead><tbody>
   <tr v-for="s in roster" :key="s.id"><td>{{s.student_no}}</td><td>{{s.display_name}}</td><td><span :class="['chip',{inactive:!s.is_active}]">{{s.is_active?'啟用':'停用'}}</span></td>
    <td><button class="danger-btn" @click="change(s)">{{s.is_active?'停用（保留歷史）':'恢復'}}</button></td></tr>
  </tbody></table></div>
 </section>
</template>

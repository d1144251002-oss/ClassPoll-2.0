<script setup lang="ts">
import {computed,onMounted,ref} from 'vue';
import {db,rpc,typedError} from '../services/api';
import {session,flash} from '../services/session';
type Course={id:string;room_id:string;term_id:string;department_id:string;code:string;title:string;status:string;student_count:number;term_label:string;unit_label:string};
type Term={id:string;academic_year:number;semester:number;starts_on:string;ends_on:string;is_archived:boolean};
type Unit={id:string;parent_id:string|null;kind:string;code:string;name:string};
type Room={id:string;title:string;code:string};
const list=ref<Course[]>([]),terms=ref<Term[]>([]),units=ref<Unit[]>([]),rooms=ref<Room[]>([]);
const error=ref(''),loading=ref(false),editing=ref(''),termYear=ref('115'),termSemester=ref(1);
const startDate=ref('2026-09-01'),endDate=ref('2027-01-20');
const unitParent=ref(''),unitKind=ref('campus'),unitCode=ref(''),unitName=ref('');
const courseTitle=ref(''),courseCode=ref(''),courseTerm=ref(''),courseDept=ref(''),courseRoom=ref('');
const isManager=computed(()=>['admin','registrar'].includes(session.staffRole));
const staffEmail=ref(''),staffRole=ref('co_teacher'),staffCourse=ref('');
const depts=computed(()=>units.value.filter(x=>x.kind==='department'));
const availableParents=computed(()=>unitKind.value==='college'?units.value.filter(x=>x.kind==='campus'):units.value.filter(x=>x.kind==='college'));
function clearForm(){editing.value='';courseTitle.value='';courseCode.value=''}
async function load(){
 loading.value=true;error.value='';
 try{
  const [c,t,u]=await Promise.all([
   rpc<Course[]>(db(),'cp3_course_list'),rpc<Term[]>(db(),'cp3_terms_list'),rpc<Unit[]>(db(),'cp3_unit_list')
  ]);
  list.value=c||[];terms.value=t||[];units.value=u||[];
  if(session.role==='teacher'){
   const {data,error:e}=await db().from('cp2_rooms').select('id,title,code').order('created_at',{ascending:false});
   if(e)throw e;rooms.value=(data||[]) as Room[];
  }
 }catch(e){error.value=typedError(e)}finally{loading.value=false}
}
async function createTerm(){
 try{await rpc(db(),'cp3_term_save',{p_term:null,p_year:Number(termYear.value),p_semester:termSemester.value,p_start:startDate.value,p_end:endDate.value});flash('學期已建立');await load()}
 catch(e){error.value=typedError(e)}
}
async function createUnit(){
 try{await rpc(db(),'cp3_unit_save',{p_id:null,p_parent:unitKind.value==='campus'?null:unitParent.value,p_kind:unitKind.value,p_code:unitCode.value.trim().toUpperCase(),p_name:unitName.value});flash('組織單位已建立');unitCode.value='';unitName.value='';await load()}
 catch(e){error.value=typedError(e)}
}
async function saveCourse(){
 try{
  const id=await rpc<string>(db(),'cp3_course_save',{p_course:editing.value||null,p_term:courseTerm.value,p_department:courseDept.value,p_room:courseRoom.value,p_code:courseCode.value,p_title:courseTitle.value});
  flash(editing.value?'課程已更新':'課程已建立');clearForm();await load();
 }catch(e){error.value=typedError(e)}
}
function edit(c:Course){editing.value=c.id;courseTitle.value=c.title;courseCode.value=c.code;courseTerm.value=c.term_id;courseDept.value=c.department_id;courseRoom.value=c.room_id;window.scrollTo({top:0,behavior:'smooth'})}
async function archive(c:Course){
 const close=c.status!=='archived';
 if(!confirm((close?'封存':'恢復')+'「'+c.title+'」？不會刪除歷史成績和選票。'))return;
 try{await rpc(db(),'cp3_course_archive',{p_course:c.id,p_archive:close});flash('課程狀態已更新');await load()}
 catch(e){error.value=typedError(e)}
}
async function grantStaff(){
 if(!staffCourse.value||!staffEmail.value)return;
 try{await rpc(db(),'cp3_course_staff_set',{p_course:staffCourse.value,p_teacher_email:staffEmail.value,p_role:staffRole.value});flash('課程教職員權限已更新');staffEmail.value=''}
 catch(e){error.value=typedError(e)}
}
onMounted(load);
</script>
<template>
 <div class="page-heading"><div><span class="eyebrow">ACADEMIC STRUCTURE</span><h1>學期、系所與課程</h1><p class="muted">學年度 → 學期 → 校區／學院／系所 → 課程。封存可恢復，保留所有原有學習紀錄。</p></div><button class="outline" @click="load" :disabled="loading">重新整理</button></div>
 <div v-if="error" class="alert error" role="alert">{{error}}</div>
 <div class="grid-2" v-if="isManager" style="margin-bottom:20px">
  <form class="panel stack" @submit.prevent="createTerm"><h2>建立學期</h2><div class="grid-2">
    <label>學年度（民國）<input type="number" min="100" max="300" v-model="termYear" required/></label>
    <label>學期<select v-model.number="termSemester"><option :value="1">第 1 學期</option><option :value="2">第 2 學期</option><option :value="3">暑期</option></select></label>
    <label>開始日期<input type="date" v-model="startDate" required/></label>
    <label>結束日期<input type="date" v-model="endDate" required/></label>
   </div><button class="primary" type="submit">建立學期</button>
  </form>
  <form class="panel stack" @submit.prevent="createUnit"><h2>建立校區／學院／系所</h2>
   <label>組織層級<select v-model="unitKind"><option value="campus">校區</option><option value="college">學院</option><option value="department">系所</option></select></label>
   <label v-if="unitKind!=='campus'">上層單位<select v-model="unitParent" required><option value="" disabled>選擇上層單位</option><option v-for="unit in availableParents" :value="unit.id" :key="unit.id">{{unit.name}}</option></select></label>
   <div class="grid-2"><label>單位代碼<input v-model="unitCode" pattern="[A-Za-z0-9_-]{2,24}" maxlength="24" required/></label><label>名稱<input v-model="unitName" maxlength="120" required/></label></div>
   <button class="primary" type="submit">建立單位</button>
  </form>
 </div>
 <div class="grid-2" style="margin-bottom:20px" v-if="session.role==='teacher'">
  <form class="panel stack" @submit.prevent="saveCourse"><h2>{{editing?'編輯課程':'新增課程'}}</h2>
   <label>開課學期<select v-model="courseTerm" required><option value="" disabled>請選擇</option><option v-for="t in terms.filter(x=>!x.is_archived)" :key="t.id" :value="t.id">{{t.academic_year}} 學年度／{{t.semester}} 學期</option></select></label>
   <label>系所<select v-model="courseDept" required><option value="" disabled>請選擇</option><option v-for="u in depts" :key="u.id" :value="u.id">{{u.name}}</option></select></label>
   <label>對應既有教室<select v-model="courseRoom" :disabled="Boolean(editing)" required><option value="" disabled>請選擇</option><option v-for="room in rooms" :key="room.id" :value="room.id">{{room.title}}（{{room.code}}）</option></select></label>
   <div class="grid-2"><label>課程代碼<input v-model.trim="courseCode" maxlength="32" required/></label><label>課程名稱<input v-model.trim="courseTitle" maxlength="160" required/></label></div>
   <div class="toolbar"><button class="primary" type="submit" :disabled="!terms.length||!depts.length||!rooms.length">儲存課程</button><button v-if="editing" type="button" class="outline" @click="clearForm">取消編輯</button></div>
  </form>
  <form class="panel stack" @submit.prevent="grantStaff"><h2>共同授課與助教授權</h2>
   <p class="muted">只能授予已加入教師白名單的帳號，授權範圍限制在指定課程。助教和稽核角色為唯讀。</p>
   <label>課程<select v-model="staffCourse" required><option value="" disabled>選擇課程</option><option v-for="c in list.filter(x=>x.status==='active')" :key="c.id" :value="c.id">{{c.title}}</option></select></label>
   <label>人員 Email<input v-model.trim="staffEmail" type="email" required/></label>
   <label>權限<select v-model="staffRole"><option value="co_teacher">共同授課教師</option><option value="assistant">助理（唯讀）</option><option value="auditor">稽核員（唯讀）</option><option value="remove">撤銷授權</option></select></label>
   <button class="primary" type="submit">更新授權</button>
  </form>
 </div>
 <section class="panel"><h2>課程清單（{{list.length}}）</h2>
  <div v-if="!list.length" class="empty">尚未建立可存取的課程。請由校務管理者先建立學期和系所。</div>
  <div v-else class="table-wrap"><table><thead><tr><th>代碼／課程</th><th>學期</th><th>系所</th><th>修課人數</th><th>狀態</th><th v-if="session.role==='teacher'">管理</th></tr></thead><tbody>
   <tr v-for="c in list" :key="c.id"><td><b>{{c.code}}</b><div>{{c.title}}</div></td><td>{{c.term_label}}</td><td>{{c.unit_label}}</td><td>{{c.student_count}}</td>
    <td><span :class="['chip',{inactive:c.status==='archived'}]">{{c.status==='active'?'進行中':'已封存'}}</span></td>
    <td v-if="session.role==='teacher'"><button class="outline" @click="edit(c)" :disabled="c.status==='archived'">編輯</button> <button class="danger-btn" @click="archive(c)">{{c.status==='archived'?'恢復':'封存'}}</button></td>
   </tr></tbody></table></div>
 </section>
</template>

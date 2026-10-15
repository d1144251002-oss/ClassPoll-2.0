<script setup lang="ts">
import {onMounted,ref,watch} from 'vue';
import {db,rpc,typedError} from '../services/api';
import {session,flash} from '../services/session';
interface Course{id:string;code:string;title:string}
interface Task{id:string;title:string;instructions:string;opens_at:string;due_at:string;max_points:number;status:string;submitted:boolean;reviewed_points:number|null}
interface Submission{id:string;student_no:string;display_name:string;latest_text:string;revision:number;points:number|null;feedback:string}
const courses=ref<Course[]>([]),course=ref(''),tasks=ref<Task[]>([]),submissions=ref<Submission[]>([]);
const selected=ref(''),error=ref(''),title=ref(''),instructions=ref(''),opens=ref(''),due=ref(''),points=ref(100),published=ref(true),content=ref('');
const grades=ref<Record<string,string>>({}),feedback=ref<Record<string,string>>({});
async function load(){try{courses.value=await rpc<Course[]>(db(),'cp3_course_list');if(!courses.value.some(x=>x.id===course.value))course.value=courses.value[0]?.id||'';await tasksLoad()}catch(e){error.value=typedError(e)}}
async function tasksLoad(){if(!course.value){tasks.value=[];return}try{tasks.value=await rpc<Task[]>(db(),'cp3_assignment_list',{p_course:course.value})}catch(e){error.value=typedError(e)}}
watch(course,tasksLoad);
async function create(){
 try{
  if(!opens.value||!due.value)throw Error('請設定開放與截止時間');
  await rpc(db(),'cp3_assignment_save',{p_id:null,p_course:course.value,p_title:title.value,p_instructions:instructions.value,p_opens:new Date(opens.value).toISOString(),p_due:new Date(due.value).toISOString(),p_points:points.value,p_publish:published.value});
  flash('作業建立成功');title.value='';instructions.value='';await tasksLoad();
 }catch(e){error.value=typedError(e)}
}
async function submit(task:Task){
 if(!confirm('確定繳交本版作業嗎？'))return;
 try{await rpc(db(),'cp3_assignment_submit',{p_assignment:task.id,p_text:content.value});content.value='';flash('作業繳交成功');await tasksLoad()}
 catch(e){error.value=typedError(e)}
}
async function loadSubmissions(task:Task){
 selected.value=task.id;try{submissions.value=await rpc<Submission[]>(db(),'cp3_submission_list',{p_assignment:task.id});
 for(const s of submissions.value){grades.value[s.id]=s.points===null?'':String(s.points);feedback.value[s.id]=s.feedback||''}
 }catch(e){error.value=typedError(e)}
}
async function grade(s:Submission){
 if(grades.value[s.id]===''||!confirm('確認覆核這份成績？'))return;
 try{await rpc(db(),'cp3_grade_review',{p_submission:s.id,p_points:Number(grades.value[s.id]),p_feedback:feedback.value[s.id]||''});flash('評分已保存並留存稽核紀錄')}
 catch(e){error.value=typedError(e)}
}
onMounted(load);
</script>
<template>
 <div class="page-heading"><div><span class="eyebrow">COURSEWORK</span><h1>作業與批改</h1><p class="muted">學生可在期限內重新提交；已批改的作業不可任意修改，評分留有稽核。</p></div><button class="outline" @click="load">更新</button></div>
 <div v-if="error" class="alert error">{{error}}</div>
 <div class="panel stack" style="margin-bottom:20px"><label>課程<select v-model="course"><option value="">選擇課程</option><option v-for="c in courses" :key="c.id" :value="c.id">{{c.code}} · {{c.title}}</option></select></label></div>
 <form v-if="session.role==='teacher'&&course" class="panel stack" style="margin-bottom:20px" @submit.prevent="create">
  <h2>新增課程作業</h2><label>標題<input v-model.trim="title" maxlength="160" required/></label>
  <label>說明<textarea v-model="instructions" maxlength="4000" rows="3"/></label>
  <div class="grid-3"><label>開放時間<input v-model="opens" type="datetime-local" required/></label><label>截止時間<input v-model="due" type="datetime-local" required/></label><label>滿分<input v-model.number="points" type="number" min="0.01" max="1000" step="0.01" required/></label></div>
  <label><input v-model="published" type="checkbox" style="width:auto"/> 立即發布</label><button type="submit" class="primary">儲存作業</button>
 </form>
 <div v-if="!tasks.length" class="empty">此課程尚未設定作業。</div>
 <div v-for="task in tasks" :key="task.id" class="panel" style="margin-bottom:14px">
  <div class="flex-space"><h2>{{task.title}}</h2><span class="chip">{{task.status}}</span></div>
  <p class="muted">{{new Date(task.opens_at).toLocaleString('zh-TW')}} 至 {{new Date(task.due_at).toLocaleString('zh-TW')}} · 滿分 {{task.max_points}}</p>
  <p style="white-space:pre-wrap">{{task.instructions}}</p>
  <button v-if="session.role==='teacher'" class="outline" @click="loadSubmissions(task)">閱卷與覆核</button>
  <template v-else><p v-if="task.submitted" class="chip">已繳交{{task.reviewed_points!==null?'，教師評分：'+task.reviewed_points:''}}</p>
   <form v-if="task.status==='published'&&new Date(task.opens_at)<=new Date()&&new Date(task.due_at)>new Date()&&task.reviewed_points===null" class="stack" @submit.prevent="submit(task)">
    <textarea v-model="content" maxlength="10000" rows="4" placeholder="請輸入作業內容" required/><button class="primary">提交作業版本</button>
   </form></template>
 </div>
 <section v-if="session.role==='teacher'&&selected" class="panel"><h2>人工成績覆核</h2><div v-for="s in submissions" :key="s.id" class="list-row" style="display:block">
  <b>{{s.student_no}} {{s.display_name}} · 第 {{s.revision}} 版</b><p style="white-space:pre-wrap">{{s.latest_text}}</p>
  <div class="grid-3"><label>分數<input v-model="grades[s.id]" type="number" min="0" step="0.01"/></label><label>回饋<input v-model="feedback[s.id]" maxlength="2000"/></label><button class="primary" @click="grade(s)">覆核評分</button></div>
 </div></section>
</template>

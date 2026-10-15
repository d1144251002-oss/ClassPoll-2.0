<script setup lang="ts">
import {onMounted,ref,watch} from 'vue';
import {db,rpc,typedError} from '../services/api';
import {flash} from '../services/session';
type Course={id:string;code:string;title:string};
type Grade={student_no:string;display_name:string;attendance_pct:number|null;quiz_pct:number|null;assignment_pct:number|null;final_pct:number|null;reviewed_assignments:number};
const courses=ref<Course[]>([]),course=ref(''),grades=ref<Grade[]>([]),error=ref('');
const attendance=ref(20),quiz=ref(40),assignment=ref(40),day=ref(''),dayName=ref('');
async function refresh(){
 try{courses.value=await rpc<Course[]>(db(),'cp3_course_list');if(!courses.value.some(x=>x.id===course.value))course.value=courses.value[0]?.id||'';await loadGrades()}
 catch(e){error.value=typedError(e)}
}
async function loadGrades(){if(!course.value){grades.value=[];return}
 try{grades.value=await rpc<Grade[]>(db(),'cp3_gradebook',{p_course:course.value})||[]}catch(e){error.value=typedError(e)}
}
async function saveWeights(){
 if(attendance.value+quiz.value+assignment.value!==100){error.value='三種成績權重加總須等於 100';return}
 try{await rpc(db(),'cp3_weights_set',{p_course:course.value,p_weights:{attendance:attendance.value,quiz:quiz.value,assignment:assignment.value}});flash('權重已保存');await loadGrades()}
 catch(e){error.value=typedError(e)}
}
async function saveSession(){
 try{await rpc(db(),'cp3_session_save',{p_course:course.value,p_date:day.value,p_title:dayName.value});dayName.value='';flash('課次已建立');await loadGrades()}
 catch(e){error.value=typedError(e)}
}
function csv(){
 const lines=[['學號','姓名','出席','測驗','作業','加權','批改作業數'],...grades.value.map(g=>[g.student_no,g.display_name,g.attendance_pct,g.quiz_pct,g.assignment_pct,g.final_pct,g.reviewed_assignments])];
 const safe=(v:unknown)=>{const s=String(v??'');return '"'+(/^[=+@-]/.test(s.trimStart())?"'"+s:s).replace(/"/g,'""')+'"'};
 const blob=new Blob(['\uFEFF'+lines.map(r=>r.map(safe).join(',')).join('\r\n')],{type:'text/csv;charset=utf-8'});
 const url=URL.createObjectURL(blob),anchor=document.createElement('a');anchor.href=url;anchor.download='ClassPoll3-成績覆核.csv';anchor.click();setTimeout(()=>URL.revokeObjectURL(url),3000);
}
watch(course,loadGrades);onMounted(refresh);
</script>
<template>
 <div class="page-heading"><div><span class="eyebrow">GRADE REVIEW</span><h1>成績簿與人工覆核</h1><p class="muted">成績資料不完整時顯示未完成，絕不自動回傳正式校務成績。</p></div><button class="outline" @click="refresh">同步</button></div>
 <div v-if="error" class="alert error">{{error}}</div>
 <div class="panel" style="margin-bottom:18px"><label class="field">課程<select v-model="course"><option value="">請選擇課程</option><option v-for="c in courses" :key="c.id" :value="c.id">{{c.title}}</option></select></label></div>
 <div v-if="course" class="grid-2" style="margin-bottom:18px">
 <form class="panel stack" @submit.prevent="saveWeights"><h2>成績權重</h2><div class="grid-3"><label>出席 %<input type="number" min="0" max="100" v-model.number="attendance"/></label><label>測驗 %<input type="number" min="0" max="100" v-model.number="quiz"/></label><label>作業 %<input type="number" min="0" max="100" v-model.number="assignment"/></label></div><p class="muted">合計 {{attendance+quiz+assignment}}%</p><button class="primary">更新</button></form>
 <form class="panel stack" @submit.prevent="saveSession"><h2>教學課次</h2><label>日期<input v-model="day" type="date" required/></label><label>名稱<input v-model.trim="dayName" maxlength="100" required/></label><button class="primary">新增課次</button></form>
 </div>
 <section class="panel"><div class="flex-space"><h2>學生學習成績</h2><button class="outline" :disabled="!grades.length" @click="csv">匯出覆核 CSV</button></div>
 <div v-if="!grades.length" class="empty">目前沒有成績資料。</div><div v-else class="table-wrap"><table><thead><tr><th>學生</th><th>出席</th><th>測驗</th><th>作業</th><th>加權</th><th>作業覆核</th></tr></thead><tbody>
 <tr v-for="g in grades" :key="g.student_no"><td>{{g.student_no}} {{g.display_name}}</td><td>{{g.attendance_pct??'尚無資料'}}</td><td>{{g.quiz_pct??'尚無資料'}}</td><td>{{g.assignment_pct??'尚無資料'}}</td><td>{{g.final_pct??'尚未完整'}}</td><td>{{g.reviewed_assignments}}</td></tr>
 </tbody></table></div></section>
</template>
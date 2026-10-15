<script setup lang="ts">
import {onMounted,ref,watch} from 'vue';
import {db,rpc,typedError} from '../services/api';
import {session,flash} from '../services/session';
type Course={id:string;code:string;title:string};
type Notice={id:string;subject:string;body:string;created_at:string;read_by_me:boolean};
const courses=ref<Course[]>([]),course=ref(''),notices=ref<Notice[]>([]),subject=ref(''),body=ref(''),error=ref('');
async function refresh(){
 try{courses.value=await rpc<Course[]>(db(),'cp3_course_list');if(!courses.value.some(c=>c.id===course.value))course.value=courses.value[0]?.id||'';await refreshNotices()}
 catch(e){error.value=typedError(e)}
}
async function refreshNotices(){
 if(!course.value){notices.value=[];return}
 try{notices.value=await rpc<Notice[]>(db(),'cp3_notice_list',{p_course:course.value})}
 catch(e){error.value=typedError(e)}
}
async function publish(){
 try{await rpc(db(),'cp3_notice_post',{p_course:course.value,p_subject:subject.value,p_body:body.value});subject.value='';body.value='';flash('公告已發布');await refreshNotices()}
 catch(e){error.value=typedError(e)}
}
async function mark(n:Notice){
 try{await rpc(db(),'cp3_notice_mark_read',{p_notice:n.id});n.read_by_me=true;flash('已標記閱讀')}
 catch(e){error.value=typedError(e)}
}
watch(course,refreshNotices);onMounted(refresh);
</script>
<template>
 <div class="page-heading"><div><span class="eyebrow">CAMPUS NOTICE CENTER</span><h1>課程公告與通知</h1><p class="muted">只顯示本人有權查看的課程公告，未讀狀態依學生身分追蹤。</p></div><button class="outline" @click="refresh">重新整理</button></div>
 <div v-if="error" class="alert error">{{error}}</div>
 <div class="panel" style="margin-bottom:18px"><label class="field">課程<select v-model="course"><option value="">目前無課程</option><option v-for="c in courses" :key="c.id" :value="c.id">{{c.code}} · {{c.title}}</option></select></label></div>
 <form v-if="session.role==='teacher'&&course" class="panel stack" style="margin-bottom:18px" @submit.prevent="publish">
 <h2>發布公告</h2><label>主旨<input v-model.trim="subject" maxlength="160" required/></label><label>內容<textarea v-model.trim="body" rows="4" maxlength="2000" required/></label>
 <button class="primary" type="submit">送出公告</button></form>
 <div v-if="!notices.length" class="empty">尚無課程公告。</div>
 <article v-for="n in notices" :key="n.id" class="panel" style="margin-bottom:12px">
 <div class="flex-space"><h2>{{n.subject}}</h2><span class="chip">{{n.read_by_me?'已讀':'未讀'}}</span></div>
 <p class="small muted">{{new Date(n.created_at).toLocaleString('zh-TW')}}</p><p style="white-space:pre-wrap">{{n.body}}</p>
 <button v-if="session.role==='student'&&!n.read_by_me" class="outline" @click="mark(n)">標記已讀</button></article>
</template>
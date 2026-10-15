import {reactive} from 'vue';
import {studentApi,teacherApi,rpc,typedError} from './api';
import type {SupabaseClient} from '@supabase/supabase-js';

type Role='teacher'|'student'|null;
export interface Member{room_id:string;display_name:string;room_title:string;student_id:string}
interface Session {
 ready:boolean;busy:boolean;role:Role;staffRole:string;identity:string;
 room:Member|null;error:string;message:string;courseId:string;
}
export const session=reactive<Session>({
 ready:false,busy:false,role:null,staffRole:'',identity:'',room:null,error:'',message:'',courseId:''
});
const pref='classpoll3-preferred-role';
const lastRoom='classpoll-2-last-room';
export const db=():SupabaseClient=>session.role==='student'?studentApi:teacherApi;
export function flash(message:string){session.message=message;session.error=''}
export function fail(e:unknown){session.error=typedError(e);session.message=''}
function resetRole(){
 session.role=null;session.staffRole='';session.identity='';session.room=null;
 session.courseId='';session.error='';session.message='';
}
async function verifyTeacher(user:{id:string;email?:string}){
 const {data,error}=await teacherApi.from('cp2_teachers').select('user_id').eq('user_id',user.id).maybeSingle();
 if(error)throw error;
 // Allow separately provisioned campus administrators, never infer admin from any email domain.
 const board=await rpc<{role:string}>(teacherApi,'cp3_dashboard');
 if(!data && !['admin','registrar','auditor'].includes(board.role))throw Error('尚未獲准進入教職員管理平台');
 session.role='teacher';session.staffRole=board.role||'teacher';session.identity=user.email||'授權教師';
 localStorage.setItem(pref,'teacher');
}
async function verifyStudent(user:{id:string;is_anonymous?:boolean}){
 if(!user.is_anonymous)return false;
 const roomId=localStorage.getItem(lastRoom);
 if(!roomId)return false;
 const resumed=await rpc<Member[]>(studentApi,'cp2_resume',{p_room:roomId});
 if(!resumed?.[0])return false;
 session.room=resumed[0];session.role='student';session.staffRole='student';
 session.identity=resumed[0].display_name;localStorage.setItem(pref,'student');return true;
}
export async function restoreSession(){
 if(session.ready)return;
 try{
  const prefRole=localStorage.getItem(pref);
  const [teacher,student]=await Promise.all([teacherApi.auth.getSession(),studentApi.auth.getSession()]);
  if(prefRole==='student'&&student.data.session?.user){
   try{if(await verifyStudent(student.data.session.user)){session.ready=true;return}}catch(e){console.warn('學生會話恢復失敗',e)}
  }
  if(teacher.data.session?.user&&!teacher.data.session.user.is_anonymous){
   try{await verifyTeacher(teacher.data.session.user);session.ready=true;return}
   catch(e){console.warn('教師會話恢復失敗',e)}
  }
  if(student.data.session?.user){
   try{if(await verifyStudent(student.data.session.user)){session.ready=true;return}}catch(e){console.warn('學生會話恢復失敗',e)}
  }
 }finally{session.ready=true}
}
export async function signInTeacher(email:string,password:string){
 session.busy=true;session.error='';
 try{
  const {data,error}=await teacherApi.auth.signInWithPassword({email:email.trim(),password});
  if(error)throw error;
  if(!data.user)throw Error('教師驗證未完成');
  await verifyTeacher(data.user);
  flash('已登入校園管理平台');
 }catch(e){fail(e);throw e}finally{session.busy=false}
}
export async function signInStudent(code:string,number:string,access:string){
 session.busy=true;session.error='';
 try{
  const current=await studentApi.auth.getSession();
  if(current.data.session&&!current.data.session.user.is_anonymous){
   const out=await studentApi.auth.signOut();if(out.error)throw out.error;
  }
  let user=(await studentApi.auth.getSession()).data.session?.user;
  if(!user?.is_anonymous){
   const signed=await studentApi.auth.signInAnonymously();if(signed.error)throw signed.error;
   user=signed.data.user;
  }
  if(!user)throw Error('無法建立學生登入工作階段');
  const rows=await rpc<Member[]>(studentApi,'cp2_join',{
   p_code:code.trim().toUpperCase(),p_number:number.trim(),p_access:access.trim()
  });
  if(!rows?.[0])throw Error('學生名冊驗證失敗');
  localStorage.setItem(lastRoom,rows[0].room_id);
  await verifyStudent(user);
  flash('已進入我的課堂');
 }catch(e){fail(e);throw e}finally{session.busy=false}
}
export async function signOut(){
 const role=session.role;
 // Detach all private DOM state before remote logout to prevent stale renders.
 resetRole();localStorage.removeItem(pref);
 if(role==='student'){localStorage.removeItem(lastRoom);await studentApi.auth.signOut()}
 else if(role==='teacher')await teacherApi.auth.signOut();
}

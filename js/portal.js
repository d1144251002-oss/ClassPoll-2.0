import {$,show,txt,client,guardConfig,query,rpc,setBusy} from './common.js';

const teacherModules=[
 {id:'overview',label:'平台總覽',icon:'▦',src:'admin.html'},
 {id:'rooms',label:'教室管理',icon:'▣',src:'teacher.html?section=rooms'},
 {id:'students',label:'學生與出席',icon:'♙',src:'teacher.html?section=students'},
 {id:'bank',label:'教學題庫',icon:'▤',src:'teacher.html?section=bank'},
 {id:'live',label:'即時課堂測驗',icon:'◉',src:'teacher.html?section=live'},
 {id:'qna',label:'課堂提問',icon:'✉',src:'teacher.html?section=qna'},
 {id:'reports',label:'學習分析與報表',icon:'▥',src:'teacher.html?section=reports'},
 {id:'audit',label:'稽核與紀錄',icon:'◷',src:'teacher.html?section=audit'},
 {id:'access',label:'權限及備份管理',icon:'⚙',src:'admin.html#backupArea'},
 {id:'ballots',label:'校園表決模組',icon:'◇',src:'ballots.html'}
];
const studentModules=[
 {id:'classroom',label:'我的課堂',icon:'◉',src:'student.html'},
 {id:'governance',label:'班級與組織表決',icon:'◇',src:'vote.html'}
];
const allowedTeacher=new Set(teacherModules.map(x=>x.id));
const allowedStudent=new Set(studentModules.map(x=>x.id));
const sessionRoomKey='classpoll-2-last-room';
const ballotRoomKey='classpoll-2-governance-last-room';
const lastRoleKey='classpoll-2-campus-last-role';
let teacherDB=null,studentDB=null,role=null,authUser=null,member=null,selected=null,frameLoadId=0,started=false;
const roleModules=()=>role==='teacher'?teacherModules:studentModules;

function reportError(e,generic='登入失敗'){
 const msg=String(e?.message||generic);
 txt('loginError',generic+ (msg && msg!==generic?'：'+msg:''));
 show('loginError',true);
 console.warn(generic,e);
}
function clearError(){show('loginError',false);txt('loginError','');}
function selectRole(which){
 const teacher=which==='teacher';
 $('teacherRole').classList.toggle('active',teacher);
 $('studentRole').classList.toggle('active',!teacher);
 $('teacherRole').setAttribute('aria-selected',String(teacher));
 $('studentRole').setAttribute('aria-selected',String(!teacher));
 show('teacherLogin',teacher);show('studentLogin',!teacher);
 clearError();
}
function parseRequestedModule(){
 return new URLSearchParams(location.search).get('module');
}
function selectModule(name,{record=true}={}){
 if(!role)return;
 const options=roleModules();const chosen=options.find(x=>x.id===name)||options[0];
 selected=chosen.id;
 txt('currentModule',chosen.label);
 txt('moduleBreadcrumb','龍華科技大學 / '+(role==='teacher'?'教學管理':'學生課堂'));
 for(const button of $('moduleNav').querySelectorAll('[data-module]')){
  const active=button.dataset.module===selected;
  button.classList.toggle('active',active);
  if(active)button.setAttribute('aria-current','page');
  else button.removeAttribute('aria-current');
 }
 const src=new URL(chosen.src,location.href);
 src.searchParams.set('embedded','1');
 // Only internally defined, same-origin module paths are ever loaded.
 if(src.origin!==location.origin)throw Error('模組來源驗證失敗');
 const iframe=$('moduleFrame');frameLoadId++;iframe.src=src.href;
 if(record){
  const url=new URL(location.href);url.searchParams.set('module',chosen.id);
  history.replaceState({module:chosen.id},'',url.pathname+url.search+url.hash);
 }
 closeMenu();
}
function drawNavigation(){
 const node=$('moduleNav');node.replaceChildren();
 for(const mod of roleModules()){
  const b=document.createElement('button');b.type='button';b.dataset.module=mod.id;
  const icon=document.createElement('span');icon.className='module-icon';icon.setAttribute('aria-hidden','true');icon.textContent=mod.icon;
  const name=document.createElement('span');name.textContent=mod.label;
  b.append(icon,name);node.append(b);
 }
 txt('sessionIdentity',role==='teacher'?(authUser?.email||'授權教職員'):(member?.display_name||'已驗證學生'));
 txt('navigationLabel',role==='teacher'?'教學管理模組':'學生使用模組');
}
function closeMenu(){
 $('unifiedSidebar').classList.remove('open');show('navBackdrop',false);
 $('menuToggle').setAttribute('aria-expanded','false');
}
function openWorkspace(which,user,info){
 role=which;authUser=user||null;member=info||null;
 localStorage.setItem(lastRoleKey,which);
 show('welcome',false);show('welcomeFooter',false);show('unifiedApp',true);
 $('teacherPassword').value='';$('studentAccess').value='';clearError();
 drawNavigation();
 const requested=parseRequestedModule(),allowed=role==='teacher'?allowedTeacher:allowedStudent;
 selectModule(allowed.has(requested)?requested:roleModules()[0].id);
}
function exitWorkspace(){
 role=null;authUser=null;member=null;selected=null;
 $('moduleFrame').removeAttribute('src');
 show('unifiedApp',false);show('welcome',true);show('welcomeFooter',true);
 $('teacherPassword').value='';$('studentAccess').value='';
 $('moduleNav').replaceChildren();closeMenu();
 const url=new URL(location.href);url.searchParams.delete('module');
 history.replaceState({},'',url.pathname+url.search+url.hash);
}
async function verifyTeacherSession(session){
 const user=session?.user;
 if(!user||user.is_anonymous)return false;
 const found=await query(teacherDB.from('cp2_teachers').select('user_id').eq('user_id',user.id).maybeSingle());
 if(!found)return false;
 openWorkspace('teacher',user);
 return true;
}
async function verifyStudentSession(session){
 if(!session?.user?.is_anonymous)return false;
 const roomId=localStorage.getItem(sessionRoomKey);
 if(!roomId)return false;
 try{
  const info=await rpc(studentDB,'cp2_resume',{p_room:roomId});
  if(!info?.length){localStorage.removeItem(sessionRoomKey);return false;}
  localStorage.setItem(ballotRoomKey,roomId);
  openWorkspace('student',session.user,info[0]);return true;
 }catch(e){
  // Network failures must not erase a valid last-room identity.
  console.warn('學生會話確認暫時失敗',e);
  return false;
 }
}
async function restoreExisting(){
 const [a,b]=await Promise.all([teacherDB.auth.getSession(),studentDB.auth.getSession()]);
 if(a.error)console.warn('教師會話讀取失敗',a.error);
 if(b.error)console.warn('學生會話讀取失敗',b.error);
 // Explicit classroom invitations always take precedence over an existing
 // staff session in the same browser. Do not silently sign students into staff UI.
 const invite=new URLSearchParams(location.search).get('room');
 if(invite && /^[A-Za-z0-9]{4,12}$/.test(invite)){
  if(b.data?.session && await verifyStudentSession(b.data.session))return;
  selectRole('student');return;
 }
 const lastRole=localStorage.getItem(lastRoleKey);
 if(lastRole==='student' && b.data?.session && await verifyStudentSession(b.data.session))return;
 if(lastRole==='teacher' && a.data?.session && await verifyTeacherSession(a.data.session))return;
 if(a.data?.session && await verifyTeacherSession(a.data.session))return;
 if(b.data?.session && await verifyStudentSession(b.data.session))return;
}
async function teacherLogin(event){
 event.preventDefault();
 const button=$('teacherSubmit');setBusy(button,true,'正在確認教師身分…');clearError();
 try{
  const {data,error}=await teacherDB.auth.signInWithPassword({
   email:$('teacherEmail').value.trim(),password:$('teacherPassword').value
  });if(error)throw error;
  const verified=await verifyTeacherSession(data.session || {user:data.user});
  if(!verified)throw Error('此帳號尚未取得教學平台教師授權，請聯繫平台管理員');
 }catch(e){reportError(e,'教師身分驗證失敗');}
 finally{$('teacherPassword').value='';setBusy(button,false);}
}
async function ensureStudentSession(){
 const {data,error}=await studentDB.auth.getSession();if(error)throw error;
 if(data.session?.user?.is_anonymous)return data.session.user;
 if(data.session?.user){
  const signedOut=await studentDB.auth.signOut();if(signedOut.error)throw signedOut.error;
 }
 const newSession=await studentDB.auth.signInAnonymously();
 if(newSession.error)throw newSession.error;
 if(!newSession.data?.user?.id)throw Error('無法取得有效的學生登入身分');
 return newSession.data.user;
}
async function studentLogin(event){
 event.preventDefault();const button=$('studentSubmit');setBusy(button,true,'正在驗證學生名冊…');clearError();
 try{
  const user=await ensureStudentSession();
  const code=$('studentRoom').value.trim().toUpperCase(),number=$('studentNumber').value.trim();
  const access=$('studentAccess').value.trim();
  const info=await rpc(studentDB,'cp2_join',{p_code:code,p_number:number,p_access:access});
  if(!Array.isArray(info)||!info.length)throw Error('入班身分驗證失敗');
  localStorage.setItem(sessionRoomKey,info[0].room_id);
  localStorage.setItem(ballotRoomKey,info[0].room_id);
  openWorkspace('student',user,info[0]);
 }catch(e){reportError(e,'學生入班失敗');}
 finally{$('studentAccess').value='';setBusy(button,false);}
}
async function logout(){
 const button=$('switchIdentity');if(button.disabled)return;
 button.disabled=true;
 const type=role;
 try{
  // Unmount personal information first, then invalidate its role-scoped session.
  localStorage.removeItem(lastRoleKey);exitWorkspace();
  if(type==='teacher'){
   const {error}=await teacherDB.auth.signOut();if(error)throw error;
   selectRole('teacher');
  }else{
   localStorage.removeItem(sessionRoomKey);localStorage.removeItem(ballotRoomKey);
   const {error}=await studentDB.auth.signOut();if(error)throw error;
   selectRole('student');
  }
 }catch(e){reportError(e,'登出操作未完成，請確認網路連線');}
 finally{button.disabled=false;}
}
function wire(){
 $('teacherRole').addEventListener('click',()=>selectRole('teacher'));
 $('studentRole').addEventListener('click',()=>selectRole('student'));
 $('teacherLogin').addEventListener('submit',teacherLogin);
 $('studentLogin').addEventListener('submit',studentLogin);
 $('moduleNav').addEventListener('click',event=>{
  const button=event.target.closest('[data-module]');if(button)selectModule(button.dataset.module);
 });
 $('menuToggle').addEventListener('click',()=>{
  const opened=!$('unifiedSidebar').classList.contains('open');
  $('unifiedSidebar').classList.toggle('open',opened);
  show('navBackdrop',opened);$('menuToggle').setAttribute('aria-expanded',String(opened));
 });
 $('navBackdrop').addEventListener('click',closeMenu);
 $('switchIdentity').addEventListener('click',logout);
 $('refreshModule').addEventListener('click',()=>{
  if(role&&selected)selectModule(selected,{record:false});
 });
 $('retryModule').addEventListener('click',()=>selectModule(selected,{record:false}));
 $('moduleFrame').addEventListener('load',()=>{
  show('moduleFallback',false);
  // Same-origin module cards should switch the parent menu instead of
  // silently replacing a child iframe while the parent breadcrumb stays stale.
  try{
   $('moduleFrame').contentDocument?.addEventListener('click',event=>{
    const anchor=event.target?.closest?.('a[href]');
    if(!anchor||event.defaultPrevented||event.ctrlKey||event.metaKey||event.shiftKey||event.altKey)return;
    const url=new URL(anchor.href,location.href);
    if(url.origin!==location.origin)return;
    const file=url.pathname.split('/').pop();
    let destination=null;
    if(role==='teacher'){
     if(file==='teacher.html')destination=anchor.textContent.includes('課堂互動')?'live':'rooms';
     if(file==='ballots.html')destination='ballots';
     if(file==='admin.html')destination='overview';
    }else if(role==='student'){
     if(file==='student.html')destination='classroom';
     if(file==='vote.html')destination='governance';
    }
    if(destination){event.preventDefault();selectModule(destination);}
   },{capture:true});
  }catch(e){console.warn('模組內部導覽同步失敗',e);}
 });
 window.addEventListener('popstate',()=>{
  if(role)selectModule(parseRequestedModule(),{record:false});
 });
 document.addEventListener('keydown',e=>{if(e.key==='Escape')closeMenu();});
}
window.addEventListener('load',async()=>{
 if(started)return;started=true;wire();selectRole('teacher');
 const inviteRoom=new URLSearchParams(location.search).get('room');
 if(inviteRoom && /^[A-Za-z0-9]{4,12}$/.test(inviteRoom)){
   $('studentRoom').value=inviteRoom.toUpperCase();selectRole('student');
 }
 if(!guardConfig())return;
 teacherDB=client('teacher');studentDB=client('student');
 if(!teacherDB||!studentDB){show('configNotice');return;}
 try{await restoreExisting();}catch(e){console.warn('會話恢復失敗',e);}
});

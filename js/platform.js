import {$,txt,show,toast,failure,setBusy,client,query,rpc,dl,exportRows,guardConfig,fmtDate} from './common.js';
import {encryptBackup,decryptBackup} from './platform-utils.js';

let db=null,user=null,authorized=false,overview={rooms:[]},roles=[],audit=[],issuedCodes=[];
let currentRoomId='',currentRoleRoom='',currentAuditRoom='',lastRequest=0;
const fmtRole=(role)=>({owner:'教室擁有者',assistant:'協作助理 · 唯讀',auditor:'稽核員 · 唯讀'})[role]||role;
const total=(name)=>overview.rooms.reduce((n,r)=>n+Number(r[name]||0),0);
const el=(tag,textValue,className='')=>{
 const v=document.createElement(tag);v.textContent=textValue??'';if(className)v.className=className;return v;
};
function error(message){txt('errorBox',message||'');show('errorBox',Boolean(message));}
function setGate(){
 show('loginGate',!authorized);show('workspace',authorized);
 txt('identity',authorized?user?.email||'授權教師':'尚未登入');
}
async function authenticate(){
 const {data,error:authError}=await db.auth.getSession();
 if(authError)throw authError;user=data.session?.user||null;authorized=false;
 if(user&&!user.is_anonymous){
  const result=await query(db.from('cp2_teachers').select('user_id').eq('user_id',user.id).maybeSingle());
  authorized=Boolean(result);
 }
 setGate();
 if(user&&!authorized)error('目前登入帳號沒有教師白名單權限。請由平台管理員核准。');
 if(authorized)await refresh();
}
async function login(event){
 event.preventDefault();const button=$('loginButton');setBusy(button,true,'登入中…');error('');
 try{
  const {error:e}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});
  if(e)throw e;await authenticate();if(authorized)toast('已進入管理中心');
 }catch(e){failure(e,'教師登入失敗');}
 finally{$('password').value='';setBusy(button,false);}
}
function resetState(){
 authorized=false;user=null;overview={rooms:[]};roles=[];audit=[];issuedCodes=[];
 $('password').value='';$('backupPassword').value='';$('backupConfirm').value='';
 $('restorePassword').value='';$('restoreFile').value='';
 show('restoreCodesPanel',false);setGate();
}
async function logout(){try{await db.auth.signOut();resetState();toast('已登出');}catch(e){failure(e,'登出失敗');}}
function fillSelector(id,items,selected,onEmpty='沒有可選教室'){
 const target=$(id);target.replaceChildren();
 if(!items.length){const opt=el('option',onEmpty);opt.value='';target.append(opt);target.disabled=true;return '';}
 target.disabled=false;
 for(const item of items){const option=el('option',item.title+' · '+item.code);option.value=item.id;target.append(option);}
 const found=items.some(x=>x.id===selected)?selected:items[0].id;target.value=found;return found;
}
async function refresh(){
 if(!authorized)return;
 const request=++lastRequest;error('');
 try{
  const data=await rpc(db,'cp2_platform_overview');
  if(request!==lastRequest||!authorized)return;
  overview=data||{rooms:[]};if(!Array.isArray(overview.rooms))overview.rooms=[];
  txt('roomTotal',overview.rooms.length);txt('studentTotal',total('active_students'));
  txt('presentTotal',total('present_today'));txt('errorTotal',total('recent_errors'));
  txt('roleSummary',overview.rooms.filter(x=>x.role==='owner').length+' 間自有教室 · '+
    overview.rooms.filter(x=>x.role!=='owner').length+' 間授權教室');
  const owners=overview.rooms.filter(x=>x.role==='owner');
  currentRoleRoom=fillSelector('roleRoom',owners,currentRoleRoom,'只有教室擁有者可分配權限');
  currentRoomId=fillSelector('backupRoom',owners,currentRoomId,'沒有可備份的自有教室');
  currentAuditRoom=fillSelector('auditRoom',overview.rooms,currentAuditRoom,'沒有可查詢的教室');
  renderRooms();await Promise.all([loadRoles(),loadAudit()]);
 }catch(e){error('管理中心資料載入失敗：'+e.message);failure(e,'管理中心同步失敗');}
}
function renderRooms(){
 const rows=overview.rooms.filter(r=>{
  const q=$('roomSearch').value.trim().toLowerCase();
  return !q||(r.code+' '+r.title+' '+fmtRole(r.role)).toLowerCase().includes(q);
 });
 const body=$('roomRows');body.replaceChildren();
 if(!rows.length){
  const tr=document.createElement('tr'),td=el('td','找不到教室，或尚未被授予教室權限。');td.colSpan=7;tr.append(td);body.append(tr);return;
 }
 for(const r of rows){
  const tr=document.createElement('tr');
  const name=el('td',r.title+' · '+r.code+(r.is_active?'':'（已停用）'));
  const roleCell=document.createElement('td'),badge=el('span',fmtRole(r.role),'pill '+(r.role==='owner'?'owner':'audit'));roleCell.append(badge);
  tr.append(name,roleCell);
  for(const value of [
    r.active_students+' / '+r.students,r.present_today,r.questions+(r.live_questions?' · 進行中 '+r.live_questions:''),r.answers,r.recent_errors
   ])tr.append(el('td',String(value)));
  if(Number(r.recent_errors)>0)tr.lastElementChild.className='danger';
  body.append(tr);
 }
}
async function loadRoles(){
 const room=currentRoleRoom;const node=$('roleList');node.replaceChildren();
 $('roleForm').querySelectorAll('input,button,select').forEach(x=>x.disabled=!room);
 if(!room){node.append(el('p','請先建立一間你擁有的教室。','muted'));return;}
 try{
  const data=await rpc(db,'cp2_role_list',{p_room:room});
  if(currentRoleRoom!==room)return;
  roles=data||[];if(!roles.length){node.append(el('p','目前沒有額外授權的教室助理或稽核員。','muted'));return;}
  for(const r of roles){const row=el('div',null,'item');
    const title=document.createElement('div');title.append(el('strong',r.email),el('small',fmtRole(r.role)));
    row.append(title,el('small',fmtDate(r.granted_at)));node.append(row);
  }
 }catch(e){failure(e,'查詢角色失敗');}
}
async function setRole(event){
 event.preventDefault();if(!currentRoleRoom)return;
 const email=$('roleEmail').value.trim(),role=$('roleType').value;
 if(!confirm('即將對 '+email+' 執行「'+fmtRole(role)+'」權限變更。確定繼續？'))return;
 const b=$('saveRole');setBusy(b,true,'儲存中…');
 try{
  await rpc(db,'cp2_role_set',{p_room:currentRoleRoom,p_email:email,p_role:role});
  $('roleEmail').value='';await loadRoles();toast('角色權限已由伺服器更新');
 }catch(e){failure(e,'變更角色失敗');}
 finally{setBusy(b,false);}
}
async function loadAudit(){
 const room=currentAuditRoom,area=$('auditRows');area.replaceChildren();
 if(!room){area.append(el('p','請選擇可查詢的教室','muted'));return;}
 try{
  const records=await rpc(db,'cp2_platform_audit',{p_room:room,p_limit:80});
  if(currentAuditRoom!==room)return;
  audit=records||[];if(!audit.length)area.append(el('p','尚無管理操作紀錄','muted'));
  for(const item of audit){
   const div=el('div',null,'item'),summary=document.createElement('div');
   summary.append(el('strong',item.event),el('small',JSON.stringify(item.details||{})));
   div.append(summary,el('small',fmtDate(item.created_at)));area.append(div);
  }
 }catch(e){failure(e,'查詢稽核紀錄失敗');}
}
async function downloadBackup(){
 if(!currentRoomId)return toast('請先選擇教室',true);
 const pass=$('backupPassword').value,confirmPass=$('backupConfirm').value;
 if(pass.length<12||pass!==confirmPass)return toast('請輸入相同且至少 12 字元的備份密碼',true);
 const b=$('downloadBackup');setBusy(b,true,'加密備份中…');
 try{
  const snapshot=await rpc(db,'cp2_room_snapshot',{p_room:currentRoomId});
  const envelope=await encryptBackup(snapshot,pass);
  const room=overview.rooms.find(x=>x.id===currentRoomId);
  dl('ClassPoll-backup-'+(room?.code||'class')+'-'+new Date().toISOString().slice(0,10)+'.json',
     JSON.stringify(envelope),'application/json;charset=utf-8');
  toast('教室快照已在瀏覽器加密下載；請將密碼與備份檔分開保存');
 }catch(e){failure(e,'備份失敗');}
 finally{$('backupPassword').value='';$('backupConfirm').value='';setBusy(b,false);}
}
function renderCodes(){
 const body=$('restoreCodes');body.replaceChildren();
 for(const s of issuedCodes){
  const tr=document.createElement('tr');
  for(const val of [s.student_no,s.display_name,s.access_code])tr.append(el('td',val));
  body.append(tr);
 }
 show('restoreCodesPanel',issuedCodes.length>0);
}
async function restore(){
 const file=$('restoreFile').files?.[0],pass=$('restorePassword').value;
 const code=$('restoreCode').value.trim().toUpperCase(),title=$('restoreTitle').value.trim();
 if(!file)return toast('請選擇加密備份檔',true);
 if(file.size>5_000_000)return toast('單一備份最多 5 MB，過大請聯繫資料庫管理員還原',true);
 if(!/^[A-Z0-9]{4,12}$/.test(code)||!title||title.length>100)return toast('請設定有效的新教室代碼與名稱',true);
 if(!confirm('將建立全新教室 '+code+' 並為每位學生重新簽發入班碼；原教室、成績與歷史紀錄不會更動。確定？'))return;
 const b=$('restoreButton');setBusy(b,true,'驗證及建立新教室…');issuedCodes=[];renderCodes();
 try{
  const obj=JSON.parse(await file.text());const snapshot=await decryptBackup(obj,pass);
  const result=await rpc(db,'cp2_room_restore_roster',{p_backup:snapshot,p_new_code:code,p_new_title:title});
  issuedCodes=result?.new_codes||[];renderCodes();
  $('restorePassword').value='';
  toast('已建立還原教室。請立刻匯出新的學生入班碼');
  await refresh();
 }catch(e){failure(e,'還原失敗（已建立的原教室不受影響）');}
 finally{$('restorePassword').value='';setBusy(b,false);}
}
function exportNewCodes(){exportRows(issuedCodes.map(s=>({學號:s.student_no,姓名:s.display_name,新入班碼:s.access_code})),
  'ClassPoll-還原名冊-新入班碼');}
function wire(){
 $('loginForm').addEventListener('submit',login);$('logoutButton').addEventListener('click',logout);
 $('refreshButton').addEventListener('click',refresh);$('roomSearch').addEventListener('input',renderRooms);
 $('roleRoom').addEventListener('change',e=>{currentRoleRoom=e.target.value;void loadRoles();});
 $('auditRoom').addEventListener('change',e=>{currentAuditRoom=e.target.value;void loadAudit();});
 $('backupRoom').addEventListener('change',e=>currentRoomId=e.target.value);
 $('roleForm').addEventListener('submit',setRole);$('downloadBackup').addEventListener('click',downloadBackup);
 $('restoreButton').addEventListener('click',restore);$('exportRestoreCodes').addEventListener('click',exportNewCodes);
 document.addEventListener('visibilitychange',()=>{if(!document.hidden&&authorized)void refresh();});
}
window.addEventListener('load',async()=>{
 wire();if(!guardConfig())return;
 db=client('teacher');if(!db)return;
 try{
  await authenticate();
  db.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT')resetState();});
 }catch(e){failure(e,'管理中心初始化失敗');}
});

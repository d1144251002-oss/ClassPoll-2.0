import {$,txt,show,escapeHtml,toast,failure,setBusy,fmtDate,asOptions,client,query,rpc,exportRows,localLink,guardConfig,listenReconnect,setErrorReporter,taipeiToday,activeParticipation} from './common.js';

let db=null, user=null, authorized=false, tab='overview', roomId='', room=null, active=null;
let rooms=[],students=[],attendance=[],bank=[],questions=[],keys=[],votes=[],audit=[],errors=[],codes=[];
let voteChannel=null,questionChannel=null, chartLive=null,chartPoll=null,chartAccuracy=null;
let interval=null,refreshing=false,requestGen=0;
import {parseRosterCSV} from './platform-utils.js';
const today=taipeiToday;
const esc=escapeHtml;
const byId=(xs,id)=>xs.find(x=>x.id===id);
const isOnline=(s)=>s.last_seen && (Date.now()-new Date(s.last_seen).getTime())<120000;
const participantVotes=(qid)=>votes.filter(x=>x.question_id===qid);
const truth=(q)=>keys.find(k=>k.question_id===q.id)?.correct_index;
const currentRoom=()=>rooms.find(x=>x.id===roomId);

function activateTab(name){
 tab=name;document.querySelectorAll('[id^="tab-"]').forEach(el=>el.classList.toggle('hidden',el.id!==`tab-${name}`));
 document.querySelectorAll('[data-tab]').forEach(el=>el.classList.toggle('nav-active',el.dataset.tab===name));
 const names={overview:'總覽儀表板',rooms:'教室管理',students:'學生與出席',bank:'我的題庫',live:'即時測驗',reports:'學習分析與匯出',audit:'操作紀錄'};
 txt('breadcrumb',names[name]);txt('pageTitle',names[name]);$('sidebar').classList.remove('open');
 if(name==='reports')renderReports();
 setTimeout(()=>{chartLive?.resize();chartPoll?.resize();chartAccuracy?.resize();},0);
}
function authUI(){
 show('authGate',!authorized);show('teacherApp',authorized);txt('teacherIdentity',user?.email||'尚未登入');
}
async function verifyTeacher(){
 if(!db)return;
 const {data:{session}}=await db.auth.getSession();user=session?.user||null;
 authorized=false;
 if(user && !user.is_anonymous){
   const permitted=await query(db.from('cp2_teachers').select('user_id').eq('user_id',user.id).maybeSingle());
   authorized=!!permitted;
   if(!authorized)toast('登入成功，但這個帳號未獲得教師權限；請管理員執行 02_grant_teacher.sql。',true);
 }
 authUI();if(authorized){await refreshAll();}
}
async function onLogin(ev){ev.preventDefault();if(!db)return;const b=$('loginBtn');setBusy(b,true);
 try{ const {error}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});if(error)throw error;
 await verifyTeacher();if(authorized)toast('已登入教師控制台');
 }catch(e){failure(e,'登入失敗');}finally{$('password').value='';setBusy(b,false);}}
function clearPrivateState(){
 authorized=false;user=null;roomId='';room=null;active=null;
 rooms=[];students=[];attendance=[];bank=[];questions=[];keys=[];votes=[];audit=[];errors=[];codes=[];
 requestGen++;renderCodes();$('password').value='';
 authUI();
}
async function onLogout(){
 if(!db)return;
 try{
   await db.auth.signOut();
   clearPrivateState();
   await clearChannels();
   toast('已登出');
 }catch(e){failure(e,'登出失敗');}
}
async function getAll(table, filter=null,sort=null){
 const list=[];for(let offset=0;offset<25000;offset+=500){
   let q=db.from(table).select('*').range(offset,offset+499);
   if(filter)q=filter(q);
   if(sort)q=q.order(sort,{ascending:false});
   const page=await query(q);list.push(...(page||[]));if(!page || page.length<500)break;
 }
 return list;
}
async function refreshAll(){
 if(!authorized||refreshing)return;refreshing=true;
 try{
   rooms=await getAll('cp2_rooms',null,'created_at');bank=await getAll('cp2_bank',null,'created_at');
   if(!roomId || !rooms.some(r=>r.id===roomId))roomId=rooms[0]?.id||'';
   renderRoomSelector();renderRooms();renderBank();await refreshRoom();
 }catch(e){failure(e,'同步管理資料失敗');}finally{refreshing=false;}
}
async function refreshRoom(){
 const generation=++requestGen;
 if(!roomId){room=null;students=[];attendance=[];questions=[];keys=[];votes=[];audit=[];errors=[];active=null;await clearChannels();renderAll();return;}
 const r=currentRoom();if(!r)return;
 try{
   const [s,a,q,log,errs]=await Promise.all([
     getAll('cp2_students',x=>x.eq('room_id',roomId),'student_no'),
     getAll('cp2_attendance',x=>x.eq('room_id',roomId),'first_seen'),
     getAll('cp2_questions',x=>x.eq('room_id',roomId),'created_at'),
     getAll('cp2_audit',x=>x.eq('room_id',roomId),'created_at'),
     getAll('cp2_errors',x=>x.eq('room_id',roomId),'created_at'),
   ]);
   const k=[],v=[];
   for(let i=0;i<q.length;i+=60){const ids=q.slice(i,i+60).map(x=>x.id);
      k.push(...await getAll('cp2_answer_keys',x=>x.in('question_id',ids)));
      v.push(...await getAll('cp2_votes',x=>x.in('question_id',ids)));
   }
   if(generation!==requestGen)return;
   room=r;students=s;attendance=a;questions=q;keys=k;votes=v;audit=log;errors=errs;
   active=q.find(x=>x.status==='published')||null;
   renderAll();await resetSubscriptions();
 }catch(e){failure(e,'載入教室資料失敗');}
}
async function refreshLiveOnly(){
 if(!authorized||!roomId)return;const expectedRoomId=roomId;
 try{
   const [q,s]=await Promise.all([
     getAll('cp2_questions',x=>x.eq('room_id',expectedRoomId),'created_at'),
     getAll('cp2_students',x=>x.eq('room_id',expectedRoomId))
   ]);
   if(expectedRoomId!==roomId)return;
   const previousActiveId=active?.id||null;
   const nextActive=q.find(x=>x.status==='published')||null;
   // Status changes and deadlines must refresh the complete question state.
   const changed=q.length!==questions.length || q.some(item=>{
     const previous=questions.find(old=>old.id===item.id);
     return !previous || previous.status!==item.status ||
       previous.ends_at!==item.ends_at || previous.published_at!==item.published_at;
   });
   if(changed || previousActiveId!==(nextActive?.id||null)){
     await refreshRoom();return;
   }
   questions=q;students=s;active=nextActive;
   if(active){
     const latestVotes=await getAll('cp2_votes',x=>x.eq('question_id',active.id));
     if(expectedRoomId!==roomId)return;
     votes=votes.filter(v=>v.question_id!==active.id).concat(latestVotes);
   }
   renderOverview();renderLive();renderStudents();
   if(tab==='reports')renderReports();
   if(active?.id!==voteChannel?.__questionId) await resetSubscriptions();
 }catch(e){console.error('增量同步失敗',e);}
}
async function clearChannels(){
 for(const ch of [voteChannel,questionChannel]) if(ch)try{await db.removeChannel(ch);}catch(e){console.warn(e)}
 voteChannel=null;questionChannel=null;
}
async function resetSubscriptions(){
 if(!db)return;await clearChannels();if(!roomId||!authorized)return;
 questionChannel=db.channel(`cp2-teacher-questions-${roomId}-${Date.now()}`).on('postgres_changes',{
   event:'*',schema:'public',table:'cp2_questions',filter:`room_id=eq.${roomId}`
 },()=>refreshRoom()).subscribe(s=>{if(s==='SUBSCRIBED')refreshLiveOnly();if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(s))networkWarning(s);});
 if(active){const qid=active.id;
   voteChannel=db.channel(`cp2-teacher-votes-${qid}-${Date.now()}`).on('postgres_changes',{
     event:'*',schema:'public',table:'cp2_votes',filter:`question_id=eq.${qid}`
   },()=>refreshLiveOnly()).subscribe(s=>{if(s==='SUBSCRIBED')refreshLiveOnly();if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(s))networkWarning(s);});
   voteChannel.__questionId=qid;
 }
}
function networkWarning(s){txt('networkBadge',`● 即時連線 ${s} · 定期補同步`);$('networkBadge').classList.add('offline');}
function renderRoomSelector(){
 $('roomSelect').innerHTML=`<option value="">選擇教室</option>`+rooms.map(r=>`<option value="${r.id}">${esc(r.title)} (${esc(r.code)})</option>`).join('');
 $('roomSelect').value=roomId;
}
function renderRooms(){
 $('roomList').innerHTML=rooms.length?rooms.map(r=>`<div class="list-item"><div><strong>${esc(r.title)}</strong><p>${esc(r.code)} · ${r.is_active?'開放中':'已停用'}</p></div><div class="inline-actions"><button class="mini" data-act="chooseRoom" data-id="${r.id}">管理</button><button class="mini" data-act="toggleRoom" data-id="${r.id}">${r.is_active?'停用':'啟用'}</button></div></div>`).join(''):'<div class="empty">尚無教室，請先建立。</div>';
}
function renderOverview(){
 txt('mRooms',rooms.length);txt('mStudents',students.filter(s=>s.is_active).length);
 txt('mAttendance',attendance.filter(a=>a.attended_on===today()).length);
 const progress=activeParticipation(students,active?participantVotes(active.id):[]);
 txt('mRate',active&&progress.percent!==null?`${progress.percent}%`:'—');
 txt('mRateSub',active?`${progress.count} 位學生已作答`:'等待題目發布');
 txt('overviewQuestion',active?.prompt||'目前沒有正在作答的題目');
 txt('overviewRoom',room?.title||'請先建立教室');txt('overviewRoomCode',room?`教室代碼：${room.code}`:'—');
 const box=$('overviewQr');box.innerHTML='';
 if(room){if(window.QRCode){new window.QRCode(box,{text:localLink('student.html',room.code),width:126,height:126,correctLevel:window.QRCode.CorrectLevel.M});}
 else {box.innerHTML='<p class="muted">QR Code 元件未載入，請使用複製連結。</p>';}}
 chartLive=barChart(chartLive,'liveChart',active?asOptions(active.options):[],active?optionCounts(active.id,asOptions(active.options).length):[]);
}
function optionCounts(qid, len){const arr=Array(len).fill(0);for(const vote of participantVotes(qid)){if(vote.choice>=0&&vote.choice<len)arr[vote.choice]++;}return arr;}
function barChart(instance,id,labels,values){
 const target=$(id);if(!target||!window.Chart)return instance;
 if(instance){instance.data.labels=labels;instance.data.datasets[0].data=values;instance.update('none');return instance;}
 return new window.Chart(target,{type:'bar',data:{labels,datasets:[{label:'作答人數',data:values,backgroundColor:'#7185e1',borderRadius:8,maxBarThickness:48}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{y:{beginAtZero:true,ticks:{precision:0},grid:{color:'#eef1f7'}},x:{grid:{display:false}}}}});
}
function renderStudents(){
 txt('rosterCount',students.length+' 人');
 $('studentRows').innerHTML=students.length?students.map(s=>`<tr><td>${esc(s.student_no)}</td><td>${esc(s.display_name)}</td><td class="${s.is_active?(isOnline(s)?'row-good':'row-warn'):'row-off'}">${s.is_active?(isOnline(s)?'● 在線':'○ 離線'):'已停用'}</td><td>${fmtDate(s.last_seen)}</td><td><button class="mini" data-act="resetStudent" data-id="${s.id}">重設入班碼</button> <button class="mini" data-act="toggleStudent" data-id="${s.id}">${s.is_active?'停用':'啟用'}</button></td></tr>`).join(''):'<tr><td colspan="5" class="empty">尚未建立學生名冊</td></tr>';
 $('attendanceRows').innerHTML=attendance.filter(a=>a.attended_on===today()).map(a=>{const s=students.find(x=>x.id===a.student_id);return `<tr><td>${esc(s?.student_no||'—')}</td><td>${esc(s?.display_name||'—')}</td><td>${fmtDate(a.first_seen)}</td></tr>`;}).join('')||'<tr><td colspan="3" class="empty">今日尚無出席紀錄</td></tr>';
}
function renderBank(){
 txt('bankCount',bank.length+' 題');
 $('selectBank').innerHTML='<option value="">手動輸入新題目</option>'+bank.map(b=>`<option value="${b.id}">${esc(b.topic)}｜${esc(b.prompt.slice(0,70))}</option>`).join('');
 $('bankList').innerHTML=bank.length?bank.map(b=>`<div class="list-item"><div><strong>${esc(b.prompt)}</strong><p>${esc(b.topic)} · ${b.points} 分 · 答案 ${'ABCDEF'[b.correct_index]}</p></div><div class="inline-actions"><button class="mini" data-act="useBank" data-id="${b.id}">發題</button><button class="mini" data-act="editBank" data-id="${b.id}">編輯</button><button class="mini" data-act="deleteBank" data-id="${b.id}">刪除</button></div></div>`).join(''):'<div class="empty">尚無題目；可於左側新增。</div>';
}
function renderLive(){
 txt('currentQuestion',active?.prompt||'尚未發布測驗題目');
 txt('liveBadge',active?'● 進行中':'● 尚無題目');
 const opts=active?asOptions(active.options):[];
 const tally=active?optionCounts(active.id,opts.length):[];
 const progress=activeParticipation(students,active?participantVotes(active.id):[]);
 txt('currentProgress',active?`已作答 ${progress.count} / ${progress.total} 人`:'尚無進行中的作答');
 txt('currentDeadline',active?.ends_at?'本題截止：'+fmtDate(active.ends_at):'本題無倒數限制');
 $('closeBtn').disabled=!active;
 chartPoll=barChart(chartPoll,'pollChart',opts,tally);
 $('voteRows').innerHTML=active?participantVotes(active.id).map(v=>{const s=students.find(x=>x.id===v.student_id);return `<tr><td>${esc(s?.student_no||'—')}</td><td>${esc(s?.display_name||'—')}</td><td>${'ABCDEF'[v.choice]||'—'} · ${esc(opts[v.choice]||'')}</td><td>${fmtDate(v.updated_at)}</td></tr>`;}).join('')||'<tr><td colspan="4" class="empty">目前尚無回答</td></tr>':'<tr><td colspan="4" class="empty">尚未開始測驗</td></tr>';
}
function computeReports(){
 const scoreMap=new Map(students.map(s=>[s.id,{學號:s.student_no,姓名:s.display_name,已作答:0,答對:0,獲得分數:0,可得總分:questions.reduce((a,q)=>a+q.points,0)}]));
 let correct=0,graded=0;
 const detail=votes.map(v=>{const q=questions.find(q=>q.id===v.question_id);const s=students.find(s=>s.id===v.student_id);const key=q&&truth(q);
 const passed=key!==undefined && v.choice===key;if(key!==undefined){graded++;if(passed)correct++;}
 const score=passed?q?.points||0:0;const rec=scoreMap.get(v.student_id);if(rec){rec.已作答++;rec.答對+=Number(passed);rec.獲得分數+=score;}
 return {學號:s?.student_no||'',姓名:s?.display_name||'',題目:q?.prompt||'',作答選項:'ABCDEF'[v.choice],正確答案:key===undefined?'':'ABCDEF'[key],是否答對:passed?'是':'否',得分:score,作答時間:fmtDate(v.updated_at)};});
 return {scores:[...scoreMap.values()],detail,correct,graded};
}
function renderReports(){
 const {scores,correct,graded}=computeReports();txt('rQuestions',questions.length);txt('rVotes',votes.length);txt('rAccuracy',graded?Math.round(correct/graded*100)+'%':'—');
 $('scoreRows').innerHTML=scores.map(s=>`<tr><td>${esc(s.學號)}</td><td>${esc(s.姓名)}</td><td>${s.已作答}</td><td>${s.答對}</td><td>${s.獲得分數}</td><td>${s.可得總分}</td></tr>`).join('')||'<tr><td colspan="6" class="empty">尚無成績資料</td></tr>';
 $('questionHistory').innerHTML=questions.map(q=>{const list=participantVotes(q.id),correct=truth(q),n=list.filter(v=>v.choice===correct).length;
 return `<div class="list-item"><div><strong>${esc(q.prompt)}</strong><p>${esc(q.status)} · ${q.points} 分 · ${list.length} 位作答 · 正確率 ${list.length?Math.round(n/list.length*100)+'%':'—'}</p></div><span class="tag">${fmtDate(q.created_at)}</span></div>`;}).join('')||'<div class="empty">尚無歷史題目</div>';
 const ordered=[...questions].reverse();chartAccuracy=barChart(chartAccuracy,'accuracyChart',ordered.map((q,i)=>`第 ${i+1} 題`),ordered.map(q=>{const l=participantVotes(q.id);return l.length?Math.round(l.filter(v=>v.choice===truth(q)).length/l.length*100):0;}));
}
function renderAudit(){
 $('errorRows').innerHTML=errors.slice(0,100).map(x=>`<tr><td>${fmtDate(x.created_at)}</td><td>${esc(x.scope)}</td><td>${esc(x.message)}</td></tr>`).join('')||'<tr><td colspan="3" class="empty">尚無錯誤回報</td></tr>';
 $('auditRows').innerHTML=audit.slice(0,150).map(a=>`<tr><td>${fmtDate(a.created_at)}</td><td>${esc(a.event)}</td><td>${esc(JSON.stringify(a.details))}</td></tr>`).join('')||'<tr><td colspan="3" class="empty">尚無操作紀錄</td></tr>';
}
function renderAll(){renderRoomSelector();renderRooms();renderOverview();renderStudents();renderBank();renderLive();renderReports();renderAudit();}
async function createRoom(ev){ev.preventDefault();const b=ev.submitter;if(!db)return;setBusy(b,true);
 try{const code=$('roomCode').value.trim().toUpperCase(),title=$('roomTitle').value.trim();if(!/^[A-Z0-9]{4,12}$/.test(code))throw Error('代碼只能使用 4~12 碼英數字');
  const created=await query(db.from('cp2_rooms').insert({code,title,owner_id:user.id}).select().single());roomId=created.id;$('roomForm').reset();await refreshAll();activateTab('students');toast('教室已建立，請開始新增學生');
 }catch(e){failure(e,'建立教室失敗');}finally{setBusy(b,false);}}
async function bulkImport(){
 if(!roomId)return toast('請先選擇教室',true);
 const b=$('bulkImport');setBusy(b,true,'正在驗證並匯入整批名冊…');
 const originalRoom=roomId;
 try{
  const parsed=parseRosterCSV($('bulkRoster').value);
  if(!confirm('將一次新增 '+parsed.length+' 位學生。若有任何學號重複或格式錯誤，資料庫會取消整批新增。確定嗎？'))return;
  const created=await rpc(db,'cp2_roster_import',{p_room:originalRoom,p_roster:parsed});
  if(!Array.isArray(created)||created.length!==parsed.length)throw Error('回傳的名冊筆數與提交不一致，請先重新查詢再操作');
  const roomForImport=rooms.find(r=>r.id===originalRoom);
  // Issued credentials are transient; no access hash is ever stored on the client.
  const newCodes=created.map(item=>({教室代碼:roomForImport?.code||'',學號:item.student_no,姓名:item.display_name,個人入班碼:item.access_code}));
  if(roomId===originalRoom){
   codes.push(...newCodes);renderCodes();$('bulkRoster').value='';
   await refreshRoom();
  }else{
   // Preserve issuance in memory even if the teacher changed the displayed room.
   codes.push(...newCodes);toast('名冊匯入成功，但你已切換教室；請立即匯出新發放的入班碼',true);
  }
  toast('已安全新增 '+created.length+' 位學生，請立即匯出入班碼');
 }catch(e){failure(e,'整批匯入取消，未新增任何學生');}
 finally{setBusy(b,false);}
}
async function createStudent(ev){ev.preventDefault();if(!roomId)return toast('請先選擇教室',true);const b=ev.submitter;setBusy(b,true);
 try{const no=$('studentNumber').value.trim(),name=$('studentName').value.trim();const result=await rpc(db,'cp2_add_student',{p_room:roomId,p_number:no,p_name:name});const entry=result?.[0];if(!entry)throw Error('未取得新學生入班碼');
 codes.push({教室代碼:room.code,學號:no,姓名:name,個人入班碼:entry.access_code});renderCodes();$('studentForm').reset();await refreshRoom();toast('學生已新增，請儲存並安全發放入班碼');
 }catch(e){failure(e,'新增學生失敗');}finally{setBusy(b,false);}}
function renderCodes(){
 show('issuedCodes',codes.length>0);
 $('codeTable').innerHTML=`<table><thead><tr><th>學號</th><th>姓名</th><th>個人入班碼</th></tr></thead><tbody>${codes.map(x=>`<tr><td>${esc(x.學號)}</td><td>${esc(x.姓名)}</td><td class="code-value">${esc(x.個人入班碼)}</td></tr>`).join('')}</tbody></table>`;
}
function bankFormData(prefix){
 const opt=[...document.querySelectorAll(`.${prefix}Option`)].map(e=>e.value.trim()).filter(Boolean);
 const correct=Number($(`${prefix}Answer`).value),points=Number($(`${prefix}Points`).value),prompt=$(`${prefix}Prompt`).value.trim();
 if(!prompt||opt.length<2||opt.length>6||!Number.isInteger(correct)||correct<0||correct>=opt.length||new Set(opt).size!==opt.length)throw Error('題目至少兩個不重複選項，且正確答案必須在選項範圍內');
 if(!Number.isInteger(points)||points<0||points>100)throw Error('分數須在 0~100');
 return {prompt,options:opt,correct_index:correct,points};
}
async function saveBank(ev){ev.preventDefault();const b=ev.submitter;setBusy(b,true);
 try{const d=bankFormData('bank'),id=$('bankEditing').value,topic=$('bankTopic').value.trim()||'未分類';
 const row={...d,topic,owner_id:user.id}; if(id){await query(db.from('cp2_bank').update(row).eq('id',id));}else{await query(db.from('cp2_bank').insert(row));}
 clearBankForm();bank=await getAll('cp2_bank',null,'created_at');renderBank();toast(id?'題目已更新':'題目已加入題庫');
 }catch(e){failure(e,'儲存題庫失敗');}finally{setBusy(b,false);}}
function clearBankForm(){$('bankForm').reset();$('bankEditing').value='';$('bankTopic').value='基本觀念';}
function loadBankToLive(b){
 $('selectBank').value=b.id;$('livePrompt').value=b.prompt;document.querySelectorAll('.liveOption').forEach((el,i)=>el.value=asOptions(b.options)[i]||'');
 $('liveAnswer').value=String(b.correct_index);$('livePoints').value=String(b.points);activateTab('live');
}
async function publish(ev){ev.preventDefault();if(!roomId)return toast('請先建立並選擇教室',true);const b=ev.submitter;setBusy(b,true);
 try{const d=bankFormData('live'),seconds=Number($('liveSeconds').value),changes=$('allowChanges').checked;
 if(!Number.isInteger(seconds)||seconds<0||seconds>7200)throw Error('限時範圍為 0~7200 秒');
 const confirmed=window.confirm('確定要發布此題？目前正在作答的題目會自動結束。');if(!confirmed)return;
 await rpc(db,'cp2_publish',{p_room:roomId,p_prompt:d.prompt,p_options:d.options,p_correct:d.correct_index,p_points:d.points,p_seconds:seconds,p_allow_changes:changes});
 await refreshRoom();toast('題目已發布，學生端將收到新題目');
 }catch(e){failure(e,'發布題目失敗');}finally{setBusy(b,false);}}
async function close(){if(!active)return;if(!confirm('確定要結束目前題目？'))return;try{await rpc(db,'cp2_close',{p_question:active.id});await refreshRoom();toast('本題已結束');}catch(e){failure(e,'結束題目失敗');}}
async function handleActions(ev){const b=ev.target.closest('[data-act]');if(!b)return;
 const {act,id}=b.dataset;
 try{
 if(act==='chooseRoom'){roomId=id;codes=[];renderCodes();await refreshRoom();activateTab('overview');}
 if(act==='toggleRoom'){const r=byId(rooms,id);if(!confirm(`確定要${r.is_active?'停用':'啟用'}教室 ${r.title}？`))return;await query(db.from('cp2_rooms').update({is_active:!r.is_active}).eq('id',id));await refreshAll();}
 if(act==='resetStudent'){const s=byId(students,id);
 if(!confirm(`重新簽發 ${s.display_name} 的入班碼？舊入班碼與舊裝置將立即失效，歷史成績會保留。`))return;
 const code=await rpc(db,'cp2_rotate_student',{p_student:id});
 codes.push({教室代碼:room.code,學號:s.student_no,姓名:s.display_name,個人入班碼:code});renderCodes();
 await refreshRoom();toast('已重新簽發入班碼，請立即儲存並交給學生');}
 if(act==='toggleStudent'){const s=byId(students,id);if(!confirm(`確定要${s.is_active?'停用':'啟用'} ${s.display_name}？`))return;await query(db.from('cp2_students').update({is_active:!s.is_active}).eq('id',id));await refreshRoom();}
 if(act==='useBank'){loadBankToLive(byId(bank,id));}
 if(act==='editBank'){const x=byId(bank,id);$('bankEditing').value=x.id;$('bankTopic').value=x.topic;$('bankPrompt').value=x.prompt;$('bankPoints').value=x.points;$('bankAnswer').value=x.correct_index;document.querySelectorAll('.bankOption').forEach((el,i)=>el.value=asOptions(x.options)[i]||'');activateTab('bank');window.scrollTo({top:0,behavior:'smooth'});}
 if(act==='deleteBank'){if(!confirm('確定刪除此題庫題目？'))return;await query(db.from('cp2_bank').delete().eq('id',id));bank=await getAll('cp2_bank',null,'created_at');renderBank();toast('題庫題目已刪除');}
 }catch(e){failure(e,'操作失敗');}
}
function exportAttendance(){const rows=attendance.map(a=>{const s=students.find(x=>x.id===a.student_id);return {教室:room?.title||'',日期:a.attended_on,學號:s?.student_no,姓名:s?.display_name,入班時間:fmtDate(a.first_seen)};});exportRows(rows,`ClassPoll-出席-${room?.code||'all'}`);}
function tick(){
 if(!authorized)return;
 if(!navigator.onLine){txt('networkBadge','● 網路離線');$('networkBadge').classList.add('offline');}
 else {txt('networkBadge','● 已連線 · 自動同步');$('networkBadge').classList.remove('offline');}
 if(active&&active.ends_at){const remaining=Math.max(0,Math.ceil((new Date(active.ends_at).getTime()-Date.now())/1000));txt('currentDeadline',remaining?`距離截止 ${Math.floor(remaining/60)}:${String(remaining%60).padStart(2,'0')}`:'答題時間已結束（教師可結束本題）');}
}
function wire(){
 $('loginForm').addEventListener('submit',onLogin);$('signoutBtn').addEventListener('click',onLogout);
 $('roomForm').addEventListener('submit',createRoom);$('studentForm').addEventListener('submit',createStudent);
 $('bankForm').addEventListener('submit',saveBank);$('publishForm').addEventListener('submit',publish);
 $('bankReset').addEventListener('click',clearBankForm);$('bulkImport').addEventListener('click',bulkImport);
 $('closeBtn').addEventListener('click',close);
 $('sideNav').addEventListener('click',e=>{const b=e.target.closest('[data-tab]');if(b)activateTab(b.dataset.tab);});
 $('menuBtn').addEventListener('click',()=>$('sidebar').classList.toggle('open'));
 document.addEventListener('click',handleActions);
 $('roomSelect').addEventListener('change',async e=>{roomId=e.target.value;codes=[];renderCodes();await refreshRoom();});
 $('selectBank').addEventListener('change',e=>{const b=byId(bank,e.target.value);if(b)loadBankToLive(b);});
 $('refreshBtn').addEventListener('click',refreshAll);
 $('copyInvite').addEventListener('click',()=>room?navigator.clipboard.writeText(localLink('student.html',room.code)).then(()=>toast('學生連結已複製')).catch(e=>failure(e,'無法複製')):toast('請先選擇教室',true));
 $('copyLiveLink').addEventListener('click',()=>room?navigator.clipboard.writeText(localLink('student.html',room.code)).then(()=>toast('學生連結已複製')).catch(e=>failure(e,'無法複製')):toast('請先選擇教室',true));
 $('exportCodes').addEventListener('click',()=>exportRows(codes,`ClassPoll-個人入班碼-${room?.code||''}`));
 $('exportAttendance').addEventListener('click',exportAttendance);
 $('exportScores').addEventListener('click',()=>exportRows(computeReports().scores,`ClassPoll-成績-${room?.code||''}`));
 $('exportVotes').addEventListener('click',()=>exportRows(computeReports().detail,`ClassPoll-作答明細-${room?.code||''}`));
 listenReconnect(()=>refreshAll());
}
window.addEventListener('load',async()=>{
 wire();if(!guardConfig())return;db=client('teacher');if(!db)return;
 setErrorReporter(db,'teacher',()=>roomId);
 try{await verifyTeacher();
 db.auth.onAuthStateChange((event)=>{
   if(event==='SIGNED_OUT'){
     clearPrivateState();
     // Auth callback should not block the SDK session transition.
     setTimeout(()=>{void clearChannels();},0);
   }
 });
 interval=setInterval(()=>{tick();if(authorized&&!document.hidden)refreshLiveOnly();},20000);setInterval(tick,1000);tick();
 }catch(e){failure(e,'初始化失敗');}
});

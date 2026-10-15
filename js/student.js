import {$,txt,show,toast,failure,setBusy,fmtDate,asOptions,client,query,rpc,guardConfig,listenReconnect,setErrorReporter} from './common.js';

let db=null,authId=null,member=null,current=null,ownVote=null,questionChannel=null;
let loading=false,pendingSync=false,sending=false,lastQuestionId=null,subscribed=false,lastSocketErrorAt=0;
const storage='classpoll-2-last-room';

function setStatus(text,ok){txt('connStatus',`${ok?'●':'○'} ${text}`);$('connStatus').style.color=ok?'#08756f':'#c27c32';}
function currentDeadline(){if(!current?.ends_at)return null;return new Date(current.ends_at).getTime()-Date.now();}
function tick(){
 if(!member)return;
 if(!navigator.onLine){setStatus('網路離線，請等待重新連線',false);return;}
 if(current?.status==='published'){
   const remaining=currentDeadline();
   if(remaining===null){txt('countdown','不限時');}
   else {const sec=Math.max(0,Math.ceil(remaining/1000));txt('countdown',sec>0?`剩餘 ${Math.floor(sec/60)}:${String(sec%60).padStart(2,'0')}`:'已截止');
     if(sec===0)document.querySelectorAll('.answer-choice').forEach(b=>b.disabled=true);
   }
 } else {txt('countdown','等待下一題');}
}
async function ensureAnonymous(){
 const session=await db.auth.getSession();if(session.error)throw session.error;
 const existing=session.data.session?.user;
 if(existing?.is_anonymous){authId=existing.id;return;}
 if(existing)await db.auth.signOut();
 const created=await db.auth.signInAnonymously();if(created.error)throw created.error;
 authId=created.data.user?.id;
 if(!authId)throw Error('匿名登入未取得有效使用者 ID');
}
async function init(){
 if(!guardConfig())return;db=client('student');if(!db)return;
 setErrorReporter(db,'student',()=>member?.room_id||null);
 try{
   setStatus('驗證學生身分中',false);await ensureAnonymous();
   const lastRoom=localStorage.getItem(storage);
   if(lastRoom){
     try{const resumed=await rpc(db,'cp2_resume',{p_room:lastRoom});if(resumed?.length)await connected(resumed[0]);else localStorage.removeItem(storage);}
     catch(e){console.warn('自動恢復失敗',e);localStorage.removeItem(storage);}
   }
 }catch(e){failure(e,'學生端初始化失敗，請在 Supabase 啟用 Anonymous Sign-ins');}
}
async function join(ev){
 ev.preventDefault();if(!db)return toast('請先完成 Supabase 設定',true);
 const b=$('joinBtn');setBusy(b,true,'驗證入班碼中…');
 try{
  await ensureAnonymous();
  const code=$('joinRoom').value.trim().toUpperCase();
  const number=$('joinNumber').value.trim();const access=$('joinAccess').value.trim();
  const joined=await rpc(db,'cp2_join',{p_code:code,p_number:number,p_access:access});
  if(!joined?.length)throw Error('入班失敗，請確認個人入班碼');
  $('joinAccess').value='';await connected(joined[0]);toast('已成功進入教室');
 }catch(e){failure(e,'無法進入教室');}finally{setBusy(b,false);}
}
async function connected(info){
 member=info;localStorage.setItem(storage,member.room_id);
 show('joinPage',false);show('studentPage',true);
 txt('studentClass',info.room_title);txt('studentIdentity',`${info.display_name} · 已完成名冊身分驗證`);
 await startStream();await syncQuestion();await heartbeat();
}
async function leave(){
 await stopStream();member=null;current=null;ownVote=null;lastQuestionId=null;pendingSync=false;
 localStorage.removeItem(storage);show('studentPage',false);show('joinPage',true);
 // Returns to admission screen without invalidating the anonymous Auth identity.
}
async function heartbeat(){
 if(!member||!db||!navigator.onLine)return;
 try{await rpc(db,'cp2_heartbeat',{p_room:member.room_id});}catch(e){console.warn('維持學生出席狀態失敗',e);}
}
async function stopStream(){if(questionChannel){try{await db.removeChannel(questionChannel);}catch(e){console.warn(e)}}questionChannel=null;subscribed=false;}
async function startStream(){
 await stopStream();if(!member)return;
 const id=member.room_id;
 questionChannel=db.channel('cp2-student-questions-'+id+'-'+Date.now()).on('postgres_changes',{
   event:'*',schema:'public',table:'cp2_questions',filter:`room_id=eq.${id}`
 },()=>syncQuestion()).subscribe(status=>{
   if(status==='SUBSCRIBED'){subscribed=true;lastSocketErrorAt=0;setStatus('即時連線正常',true);syncQuestion();}
   if(['CHANNEL_ERROR','TIMED_OUT','CLOSED'].includes(status)){subscribed=false;lastSocketErrorAt=Date.now();setStatus('連線中斷，正在定期補同步',false);}
 });
}
async function syncQuestion(){
 if(!member)return;
 // Don't drop a Realtime update while an older HTTP request is in flight.
 if(loading){pendingSync=true;return;}
 loading=true;
 const roomId=member.room_id;
 try{
   const qs=await query(db.from('cp2_questions').select('id,room_id,prompt,options,points,allow_changes,status,published_at,ends_at')
      .eq('room_id',roomId).in('status',['published','closed']).order('published_at',{ascending:false}).limit(1));
   if(member?.room_id!==roomId)return; // Ignore responses from a room already left.
   const newest=qs?.[0]||null;
   let answer=null;
   if(newest?.status==='published'){
     answer=await query(db.from('cp2_votes').select('id,choice,updated_at').eq('question_id',newest.id).maybeSingle());
   }
   if(member?.room_id!==roomId)return;
   current=newest;
   ownVote=answer;
   renderQuestion();
   if(navigator.onLine)setStatus(subscribed?'即時連線正常':'自動補同步正常',true);
 }catch(e){
   if(member?.room_id===roomId){setStatus('同步失敗 · 重新嘗試',false);console.error('題目讀取失敗',e);}
 }finally{
   loading=false;
   if(pendingSync){pendingSync=false;void syncQuestion();}
 }
}
function renderQuestion(){
 const q=current;
 show('waitCard',!q);show('closedCard',!!q && q.status==='closed');show('questionCard',!!q && q.status==='published');
 if(!q || q.status!=='published')return;
 if(lastQuestionId!==q.id){lastQuestionId=q.id;toast('收到新的課堂題目');}
 txt('studentQuestion',q.prompt);txt('pointsTag',`${q.points} 分`);
 txt('answerPolicy',q.allow_changes?'可在截止前更改選項':'提交後不可更改答案');
 const options=asOptions(q.options);
 $('answerButtons').replaceChildren();
 options.forEach((opt,i)=>{
   const button=document.createElement('button');button.type='button';button.className='answer-choice';
   if(ownVote?.choice===i)button.classList.add('selected');
   button.disabled=sending || (ownVote&&!q.allow_changes) || (currentDeadline()!==null && currentDeadline()<=0);
   const badge=document.createElement('span');badge.className='letter';badge.textContent='ABCDEF'[i];
   const caption=document.createElement('span');caption.textContent=opt;button.append(badge,caption);
   button.addEventListener('click',()=>sendAnswer(i));$('answerButtons').append(button);
 });
 show('submitState',!!ownVote);
 if(ownVote){$('submitState').className='submit-state';txt('submitState',`✓ 已儲存答案：${'ABCDEF'[ownVote.choice]} · ${fmtDate(ownVote.updated_at)}`);}
 tick();
}
async function sendAnswer(choice){
 if(!current||sending)return;
 if(ownVote&&!current.allow_changes)return toast('此題已提交，不允許修改',true);
 if(currentDeadline()!==null&&currentDeadline()<=0){toast('已超過答題截止時間',true);return;}
 sending=true;
 const qid=current.id;
 document.querySelectorAll('.answer-choice').forEach(b=>b.disabled=true);
 show('submitState',true);$('submitState').className='submit-state sending';txt('submitState','正在提交到資料庫…');
 try{
   const voteId=await rpc(db,'cp2_vote',{p_question:qid,p_choice:choice});
   if(!voteId)throw Error('伺服器未確認投票成功');
   // The RPC confirmation is authoritative. A temporary read failure should not
   // label a committed answer as failed (which would encourage duplicate votes).
   let stored=null;
   try{
     stored=await query(db.from('cp2_votes').select('id,choice,updated_at').eq('question_id',qid).maybeSingle());
   }catch(e){console.warn('投票已寫入，回讀暫時失敗，稍後會補同步',e);}
   if(stored && stored.choice!==choice)throw Error('伺服器回讀的答案與提交內容不一致');
   ownVote=stored||{id:voteId,choice,updated_at:new Date().toISOString()};
   if(current?.id===qid)renderQuestion();
   toast(stored?'答案已由 Supabase 確認儲存':'投票已由伺服器接受，正在重新確認結果');
   if(!stored)void syncQuestion();
 }catch(e){
   $('submitState').className='submit-state fail';txt('submitState','✕ 送出失敗，請確認網路後重試');
   failure(e,'投票失敗');
 }finally{
   sending=false;
   // Refresh current state so buttons are reenabled only if allowed and within the deadline.
   if(current?.id===qid && ownVote)renderQuestion();
   else if(current?.id===qid)document.querySelectorAll('.answer-choice').forEach(b=>b.disabled=currentDeadline()!==null&&currentDeadline()<=0);
 }
}
window.addEventListener('load',async()=>{
 const room=new URLSearchParams(location.search).get('room');if(room)$('joinRoom').value=room;
 $('joinForm').addEventListener('submit',join);$('leaveBtn').addEventListener('click',leave);
 listenReconnect(async()=>{if(!db)return;try{db.realtime.connect();if(member){await ensureAnonymous();await startStream();await syncQuestion();await heartbeat();}}catch(e){failure(e,'重新連線失敗');}});
 setInterval(()=>{if(member&&!document.hidden){syncQuestion();heartbeat();if(!subscribed&&navigator.onLine&&(!questionChannel||(lastSocketErrorAt&&Date.now()-lastSocketErrorAt>25000)))startStream();}},15000);
 setInterval(tick,1000);
 await init();
});

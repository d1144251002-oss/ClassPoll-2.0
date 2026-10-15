import {$,show,txt,escapeHtml as esc,toast,failure,setBusy,client,rpc,guardConfig} from './common.js';

let db=null,member=null,ballots=[],loading=false,pendingSync=false,lastRenderSignature='';
const storedRoom='classpoll-2-governance-last-room';
function announce(message,bad=false){txt('connStatus',message);$('connStatus').style.color=bad?'#a0414b':'#1c6065';}
function dateText(value){return new Date(value).toLocaleString('zh-TW',{hour12:false});}
function state(b){
 const now=Date.now();
 if(b.status==='closed'||new Date(b.closes_at).getTime()<=now)return {label:'投票已結束',css:'closed',open:false};
 if(new Date(b.opens_at).getTime()>now)return {label:'即將開始',css:'wait',open:false};
 return {label:'開放投票',css:'',open:b.status==='active'};
}
function renderSignature(items){
 // Ignore periodic metadata reads that did not change ballot content or state.
 // Preserve students' in-progress radio / checkbox selections.
 return JSON.stringify(items.map(b=>[
  b.id,b.title,b.description,b.mode,b.options,b.min_choices,b.max_choices,
  b.opens_at,b.closes_at,b.status,b.eligible_count,b.has_voted,b.receipt,
  b.results_available,b.min_report_votes,state(b).label
 ]));
}
async function anonymousSession(){
 const {data,error}=await db.auth.getSession();if(error)throw error;
 const user=data.session?.user;
 if(user?.is_anonymous)return;
 if(user)await db.auth.signOut();
 const response=await db.auth.signInAnonymously();
 if(response.error)throw response.error;
 if(!response.data.user?.id)throw Error('匿名驗證失敗');
}
async function resume(){
 const room=localStorage.getItem(storedRoom);
 if(!room)return;
 const {data,error}=await db.auth.getSession();if(error)throw error;
 if(!data.session?.user?.is_anonymous){localStorage.removeItem(storedRoom);return;}
 try{
  const data=await rpc(db,'cp2_resume',{p_room:room});
  if(data?.[0])await enterRoom(data[0]);else localStorage.removeItem(storedRoom);
 }catch(e){console.warn('恢復投票教室失敗',e);localStorage.removeItem(storedRoom);}
}
async function join(event){
 event.preventDefault();const btn=$('joinBtn');setBusy(btn,true,'正在驗證資格…');
 try{
  await anonymousSession();
  const code=$('joinRoom').value.trim().toUpperCase();
  const student=$('joinNumber').value.trim();
  const access=$('joinAccess').value.trim();
  const result=await rpc(db,'cp2_join',{p_code:code,p_number:student,p_access:access});
  if(!result?.[0])throw Error('入班驗證失敗');
  $('joinAccess').value='';
  await enterRoom(result[0]);toast('名冊身分已驗證');
 }catch(e){failure(e,'入班失敗');}
 finally{setBusy(btn,false);$('joinAccess').value='';}
}
async function enterRoom(info){
 member=info;lastRenderSignature='';localStorage.setItem(storedRoom,member.room_id);
 show('joinGate',false);show('voterApp',true);txt('roomName',info.room_title);txt('studentName',info.display_name+' · 名冊身分已驗證');
 await sync();
}
function leave(){
 member=null;ballots=[];pendingSync=false;lastRenderSignature='';
 localStorage.removeItem(storedRoom);$('ballotCards').replaceChildren();
 show('voterApp',false);show('joinGate',true);
}
async function sync(){
 if(!member)return;
 if(loading){pendingSync=true;return;}loading=true;
 const roomId=member.room_id;
 try{
  const response=await rpc(db,'cp2_ballot_list',{p_room:roomId});
  if(member?.room_id!==roomId)return;
  ballots=response||[];
  const signature=renderSignature(ballots);
  if(signature!==lastRenderSignature){lastRenderSignature=signature;render();}
  announce('投票狀態已同步 · 伺服器負責驗證投票期間與單人單票');
 }catch(e){if(member?.room_id===roomId){announce('連線不穩，稍後重試',true);console.error('表決同步失敗',e);}}
 finally{loading=false;if(pendingSync){pendingSync=false;void sync();}}
}
function render(){
 const area=$('ballotCards');area.replaceChildren();
 if(!ballots.length){const p=document.createElement('p');p.className='gov-muted';p.textContent='這個教室目前沒有已啟用的正式表決。';area.append(p);return;}
 for(const b of ballots){
  const status=state(b);
  const card=document.createElement('article');card.className='gov-item';card.dataset.ballot=b.id;
  const headline=document.createElement('div');headline.className='gov-item-head';
  const heading=document.createElement('div');const title=document.createElement('h3');title.textContent=b.title;heading.append(title);
  const mode=document.createElement('div');mode.className='gov-item-meta';
  mode.textContent=(b.mode==='multiple'?'複選制，可選 '+b.min_choices+'～'+b.max_choices+' 項':b.mode==='yesno'?'表決制':'單選制')+' · 資格名冊 '+b.eligible_count+' 人';
  heading.append(mode);
  const badge=document.createElement('span');badge.className='gov-badge '+status.css;badge.textContent=status.label;headline.append(heading,badge);card.append(headline);
  if(b.description){const desc=document.createElement('p');desc.textContent=b.description;card.append(desc);}
  const time=document.createElement('p');time.className='gov-item-meta';time.textContent='開放：'+dateText(b.opens_at)+'　截止：'+dateText(b.closes_at);card.append(time);
  if(b.has_voted){
   const done=document.createElement('div');done.className='gov-receipt';
   done.textContent='✓ 你的選票已提交。收件憑證：'+(b.receipt||'已登記')+'。請保留此憑證；它不會記錄你的選擇。';card.append(done);
  }else if(status.open){
   const form=document.createElement('form');form.className='gov-vote-form';form.dataset.ballot=b.id;
   const legend=document.createElement('p');legend.className='gov-muted';legend.textContent='請選擇 '+b.min_choices+(b.min_choices===b.max_choices?'':' 至 '+b.max_choices)+' 項：';form.append(legend);
   const group='ballot-'+b.id;
   b.options.forEach((option,i)=>{
    const label=document.createElement('label');label.className='gov-choice';
    const input=document.createElement('input');input.type=b.mode==='multiple'?'checkbox':'radio';input.name=group;input.value=i;input.dataset.choice='yes';
    const span=document.createElement('span');span.textContent=option;
    label.append(input,span);form.append(label);
   });
   const button=document.createElement('button');button.className='gov-primary';button.type='submit';button.textContent='確認並提交選票（提交後不可更改）';form.append(button);card.append(form);
  }else if(status.css==='wait'){
   const info=document.createElement('p');info.className='gov-note';info.textContent='目前尚未開放，開放後將自動顯示可選選項。';card.append(info);
  }
  if((status.css==='closed')&&!b.results_available){
   const info=document.createElement('p');info.className='gov-note';info.textContent='目前未達最低統計公開門檻（'+b.min_report_votes+' 票），為保障隱私不提供選項統計。';card.append(info);
  }else if(status.css==='closed'&&b.results_available){
   const btn=document.createElement('button');btn.className='gov-outline';btn.type='button';btn.dataset.action='result';btn.dataset.ballot=b.id;
   btn.textContent='查看已公布的彙總結果';card.append(btn);
   const result=document.createElement('div');result.className='gov-small-chart hidden';result.dataset.result=b.id;card.append(result);
  }
  area.append(card);
 }
}
async function cast(event){
 const form=event.target.closest('.gov-vote-form');if(!form)return;
 event.preventDefault();const b=ballots.find(x=>x.id===form.dataset.ballot);
 if(!b||b.has_voted)return toast('此表決已投票',true);
 const picks=[...form.querySelectorAll('input[data-choice]:checked')].map(x=>Number(x.value));
 if(picks.length<b.min_choices||picks.length>b.max_choices)return toast('選擇數量不符合規則',true);
 if(!confirm('這張選票提交後不可更改，確定選擇以上項目並送出嗎？'))return;
 const btn=form.querySelector('button[type=submit]');setBusy(btn,true,'正在提交至伺服器…');
 try{
  const receipt=await rpc(db,'cp2_ballot_cast',{p_ballot:b.id,p_choices:picks});
  if(!receipt)throw Error('伺服器沒有回傳收件憑證');
  b.has_voted=true;b.receipt=receipt;lastRenderSignature=renderSignature(ballots);render();
  toast('選票已成功提交，請保存收件憑證');void sync();
 }catch(e){failure(e,'投票未完成');}
 finally{setBusy(btn,false);}
}
async function showResult(event){
 const btn=event.target.closest('button[data-action=result]');if(!btn)return;
 const b=ballots.find(x=>x.id===btn.dataset.ballot);if(!b||!b.results_available)return;
 const box=$all('[data-result]').find(x=>x.dataset.result===b.id);if(!box)return;
 if(!box.classList.contains('hidden')){box.classList.add('hidden');return;}
 setBusy(btn,true,'取得公告結果…');
 try{
  const rows=await rpc(db,'cp2_ballot_results',{p_ballot:b.id});
  box.replaceChildren();
  for(const r of rows||[]){
   const total=Number(r.total_ballots),votes=Number(r.votes),percent=total?Math.round(votes/total*100):0;
   const line=document.createElement('div');line.className='gov-result-line';
   const label=document.createElement('span');label.textContent=r.choice_label;
   const value=document.createElement('b');value.textContent=votes+' 票（'+percent+'%）';line.append(label,value);
   const bg=document.createElement('div');bg.className='gov-progress';
   const bar=document.createElement('div');bar.className='gov-progress-fill';bar.style.width=Math.min(100,percent)+'%';bg.append(bar);
   box.append(line,bg);
  }
  box.classList.remove('hidden');
 }catch(e){failure(e,'取得彙總結果失敗');}
 finally{setBusy(btn,false);}
}
const $all=(selector)=>[...document.querySelectorAll(selector)];
function wire(){
 $('joinForm').addEventListener('submit',join);
 $('reloadBtn').addEventListener('click',sync);
 $('leaveBtn').addEventListener('click',leave);
 $('ballotCards').addEventListener('submit',cast);
 $('ballotCards').addEventListener('click',showResult);
 window.addEventListener('online',()=>{if(member)void sync();});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden&&member)void sync();});
 setInterval(()=>{if(member&&!document.hidden)void sync();},20000);
}
window.addEventListener('load',async()=>{
 wire();const param=new URLSearchParams(location.search).get('room');if(param)$('joinRoom').value=param;
 if(!guardConfig())return;db=client('student');if(!db)return;
 try{await resume();}catch(e){failure(e,'學生投票初始化失敗');}
});

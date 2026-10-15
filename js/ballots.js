import {$,show,txt,escapeHtml as esc,toast,failure,setBusy,client,query,rpc,guardConfig,exportRows,localLink} from './common.js';

let db=null,authorized=false,user=null,rooms=[],roomId='',ballots=[],loadedResults=[],activeResult=null,refreshing=false,editingId=null;
const $all=(selector)=>[...document.querySelectorAll(selector)];
function alertError(message){
  txt('errorAlert',message);show('errorAlert',Boolean(message));
}
function dateInput(value){
 const d=new Date(value);const pad=n=>String(n).padStart(2,'0');
 return [d.getFullYear(),pad(d.getMonth()+1),pad(d.getDate())].join('-')+'T'+pad(d.getHours())+':'+pad(d.getMinutes());
}
function timeLabel(s){return new Date(s).toLocaleString('zh-TW',{hour12:false});}
function initDates(){
 $('endsAt').value=dateInput(Date.now()+86400000);
 $('startsAt').value=dateInput(Date.now()+60000);
}
function updateMode(){
 const mode=$('ballotMode').value;
 if(mode==='yesno'){$('ballotOptions').value='贊成\n反對\n棄權';$('ballotOptions').readOnly=true;}
 else {$('ballotOptions').readOnly=false;if($('ballotOptions').value==='贊成\n反對\n棄權')$('ballotOptions').value='';}
 const multi=mode==='multiple';
 $('minChoices').disabled=!multi;$('maxChoices').disabled=!multi;
 if(!multi){$('minChoices').value='1';$('maxChoices').value='1';}
}
function authView(){
 show('loginGate',!authorized);show('dashboard',authorized);
 txt('adminIdentity',authorized?user?.email||'授權管理員':'');
}
async function verify(){
 const {data,error}=await db.auth.getSession();if(error)throw error;
 const authUser=data.session?.user;user=authUser||null;
 authorized=false;
 if(authUser&&!authUser.is_anonymous){
   const row=await query(db.from('cp2_teachers').select('user_id').eq('user_id',authUser.id).maybeSingle());
   authorized=Boolean(row);
 }
 authView();
 if(authorized)await loadRooms();
 else if(authUser)alertError('此登入帳號沒有教師權限，請管理員授權後再試。');
}
async function signIn(event){
 event.preventDefault();const btn=$('loginBtn');setBusy(btn,true,'正在驗證…');alertError('');
 try{
   const {error}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});
   if(error)throw error;
   await verify();
   if(authorized)toast('已登入正式表決管理中心');
 }catch(e){failure(e,'登入失敗');}
 finally{$('password').value='';setBusy(btn,false);}
}
async function signOut(){
 if(!db)return;
 try{
  await db.auth.signOut();authorized=false;user=null;rooms=[];roomId='';ballots=[];activeResult=null;loadedResults=[];
  show('resultSection',false);authView();$('password').value='';toast('已安全登出');
 }catch(e){failure(e,'登出失敗');}
}
async function loadRooms(){
 rooms=await query(db.from('cp2_rooms').select('id,title,code,is_active').order('created_at',{ascending:false}));
 $('roomSelect').replaceChildren();
 const initial=document.createElement('option');initial.value='';initial.textContent='請選擇教室';$('roomSelect').append(initial);
 for(const r of rooms){const option=document.createElement('option');option.value=r.id;option.textContent=r.title+' ('+r.code+')'+(r.is_active?'':' · 停用');$('roomSelect').append(option);}
 if(!rooms.some(x=>x.id===roomId))roomId=rooms[0]?.id||'';
 $('roomSelect').value=roomId;
 await loadBallots();
}
async function loadBallots(){
 if(!authorized||!roomId){ballots=[];renderList();return;}
 if(refreshing)return;refreshing=true;const originalRoom=roomId;
 try{
  const items=await rpc(db,'cp2_ballot_list',{p_room:roomId});
  if(originalRoom!==roomId)return;
  ballots=items||[];renderList();
 }catch(e){failure(e,'載入表決失敗');}
 finally{refreshing=false;}
}
function statusText(b){
 if(b.status==='draft')return {text:'草稿未啟用',style:'draft'};
 if(b.status==='closed'||new Date(b.closes_at).getTime()<=Date.now())return {text:'表決已結束',style:'closed'};
 if(new Date(b.opens_at).getTime()>Date.now())return {text:'等待開放',style:'wait'};
 return {text:'正在投票',style:''};
}
function renderList(){
 const node=$('ballotList');node.replaceChildren();
 if(!roomId){node.innerHTML='<p class="gov-muted">目前沒有教室。請先到課堂管理建立教室與學生名冊。</p>';return;}
 if(!ballots.length){node.innerHTML='<p class="gov-muted">尚無表決，請先從左側建立草稿。</p>';return;}
 for(const b of ballots){
  const s=statusText(b);
  const item=document.createElement('article');item.className='gov-item';
  const count=Number(b.cast_count),eligible=Number(b.eligible_count);
  const turnout=count>=0?(eligible?Math.round(count/eligible*100):0):null;
  const buttons=b.status==='draft'
    ? '<button type="button" class="gov-outline" data-action="edit" data-id="'+b.id+'">編輯草稿</button><button type="button" class="gov-primary" data-action="activate" data-id="'+b.id+'">啟用並凍結資格</button>'
    : (s.style!=='closed'?'<button type="button" class="gov-outline gov-danger" data-action="close" data-id="'+b.id+'">提前結束</button>':'')+
      '<button type="button" class="gov-outline" data-action="invite" data-id="'+b.id+'">複製投票連結</button>'+
      (b.results_available?'<button type="button" class="gov-outline" data-action="results" data-id="'+b.id+'">查看彙總結果</button>':'');
  item.innerHTML='<div class="gov-item-head"><div><h3>'+esc(b.title)+'</h3><div class="gov-item-meta">'+esc(b.mode==='multiple'?'複選制':b.mode==='yesno'?'贊成／反對／棄權':'單選制')+' · '+b.options.length+' 個選項</div></div><span class="gov-badge '+s.style+'">'+s.text+'</span></div>'+
   (b.description?'<p>'+esc(b.description)+'</p>':'')+
   '<p class="gov-item-meta">開放：'+esc(timeLabel(b.opens_at))+'<br>截止：'+esc(timeLabel(b.closes_at))+'</p>'+
   (b.status==='draft'?'<p class="gov-note">草稿可先核對設定；啟用後將鎖定名冊與選項，無法修改。</p>':
      '<div class="gov-item-meta">凍結資格：'+eligible+' 人 · 已完成投票：'+(count<0?'—':count+' 人')+' · 結果公開門檻：'+b.min_report_votes+' 票</div>'+
      (turnout===null?'':'<div class="gov-progress"><div class="gov-progress-fill" style="width:'+Math.min(100,turnout)+'%"></div></div>'))+
   (s.style==='closed'&&!b.results_available&&b.status!=='draft'?'<p class="gov-note">票數未達公開門檻，結果不會開放。</p>':'')+
   '<div class="gov-actions">'+buttons+'</div>';
  node.append(item);
 }
}
function resetEditor(){
 editingId=null;$('createForm').reset();$('startNow').checked=true;
 $('startsAt').disabled=true;initDates();updateMode();
 txt('formTitle','建立正式表決草稿');txt('createBtn','建立草稿（不立即啟用）');
 show('cancelEdit',false);
}
function editDraft(b){
 if(b.status!=='draft')return toast('已啟用的投票不得修改',true);
 editingId=b.id;
 $('ballotTitle').value=b.title;$('ballotDescription').value=b.description||'';
 $('ballotMode').value=b.mode;updateMode();
 $('ballotOptions').value=b.options.join('\n');
 $('minChoices').value=b.min_choices;$('maxChoices').value=b.max_choices;
 $('startNow').checked=false;$('startsAt').disabled=false;$('startsAt').value=dateInput(b.opens_at);
 $('endsAt').value=dateInput(b.closes_at);$('reportMin').value=b.min_report_votes;
 txt('formTitle','編輯表決草稿');txt('createBtn','儲存草稿修改');
 show('cancelEdit',true);$('createForm').scrollIntoView({behavior:'smooth',block:'start'});
}
async function createBallot(event){
 event.preventDefault();if(!roomId)return toast('請先選擇教室',true);
 const btn=$('createBtn');setBusy(btn,true,'正在建立草稿…');
 try{
  const title=$('ballotTitle').value.trim(),mode=$('ballotMode').value;
  const options=$('ballotOptions').value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
  const min=mode==='multiple'?Number($('minChoices').value):1;
  const max=mode==='multiple'?Number($('maxChoices').value):1;
  const opens=$('startNow').checked?new Date(Date.now()-1000):new Date($('startsAt').value);
  const closes=new Date($('endsAt').value);
  const minReport=Number($('reportMin').value);
  if(options.length<2||options.length>16)throw Error('選項須介於 2 至 16 項');
  if(options.some(x=>x.length>120)||new Set(options.map(x=>x.toLocaleLowerCase())).size!==options.length)throw Error('選項長度超過 120 字或有重複內容');
  if(!Number.isInteger(min)||!Number.isInteger(max)||min<1||max<min||max>options.length)throw Error('最低與最高可選數不合法');
  if(!Number.isInteger(minReport)||minReport<1||minReport>100)throw Error('最低公開票數請設定為 1～100');
  if(!Number.isFinite(opens.getTime())||!Number.isFinite(closes.getTime())||closes<=opens||closes<=new Date())throw Error('開放／截止時間不合法');
  if(minReport===1&&!confirm('公開門檻只有 1 票，可能讓小型選舉洩露投票意向。確定繼續嗎？'))return;
  const values={p_title:title,p_description:$('ballotDescription').value,
   p_mode:mode,p_options:options,p_min:min,p_max:max,p_opens:opens.toISOString(),p_closes:closes.toISOString(),p_report_min:minReport};
  if(editingId)await rpc(db,'cp2_ballot_update',{p_ballot:editingId,...values});
  else await rpc(db,'cp2_ballot_create',{p_room:roomId,...values});
  toast(editingId?'草稿已更新':'正式表決草稿已建立，核對後可啟用');
  resetEditor();await loadBallots();
 }catch(e){failure(e,'建立表決失敗');}
 finally{setBusy(btn,false);}
}
async function handleAction(event){
 const btn=event.target.closest('[data-action]');if(!btn)return;
 const action=btn.dataset.action;const ballot=ballots.find(x=>x.id===btn.dataset.id);if(!ballot)return;
 setBusy(btn,true,'處理中…');
 try{
  if(action==='edit'){editDraft(ballot);return;}
  if(action==='activate'){
   if(!confirm('啟用後會凍結此刻有效的學生資格，題目與選項不可更改。確定啟用？'))return;
   const count=await rpc(db,'cp2_ballot_activate',{p_ballot:ballot.id});
   toast('已啟用，投票資格已凍結：'+count+' 人');await loadBallots();
  }
  if(action==='close'){
   if(!confirm('確定提前結束？結束後無法重新開啟。'))return;
   await rpc(db,'cp2_ballot_close',{p_ballot:ballot.id});
   toast('已結束投票');await loadBallots();
  }
  if(action==='invite'){
   const classroom=rooms.find(x=>x.id===roomId);
   const url=localLink('vote.html',classroom?.code||'');
   await navigator.clipboard.writeText(url);toast('學生正式投票連結已複製');
  }
  if(action==='results')await showResults(ballot);
 }catch(e){failure(e,'表決操作失敗');}
 finally{setBusy(btn,false);}
}
async function showResults(ballot){
 const records=await rpc(db,'cp2_ballot_results',{p_ballot:ballot.id});
 loadedResults=records||[];activeResult=ballot;
 txt('resultTitle',ballot.title);
 const total=Number(records?.[0]?.total_ballots||0),eligible=Number(ballot.eligible_count);
 txt('resultMeta','正式提交 '+total+' 票 · 資格名冊 '+eligible+' 人 · 投票率 '+(eligible?Math.round(total/eligible*100):0)+'% · 多選制選項票數加總可能超過提交票數');
 const container=$('resultChart');container.replaceChildren();
 for(const record of loadedResults){
  const votes=Number(record.votes),ratio=total?Math.round(votes/total*100):0;
  const row=document.createElement('div');row.className='gov-result-item';
  const label=document.createElement('div');label.className='gov-result-line';
  const name=document.createElement('span');name.textContent=record.choice_label;
  const count=document.createElement('b');count.textContent=votes+' 票（'+ratio+'%）';
  label.append(name,count);
  const progress=document.createElement('div');progress.className='gov-progress';
  const bar=document.createElement('div');bar.className='gov-progress-fill';bar.style.width=Math.min(100,ratio)+'%';progress.append(bar);
  row.append(label,progress);container.append(row);
 }
 show('resultSection',true);$('resultSection').scrollIntoView({behavior:'smooth',block:'start'});
}
function exportResults(){
 if(!activeResult||!loadedResults.length)return toast('尚無可匯出的結果',true);
 exportRows(loadedResults.map(x=>({表決:activeResult.title,選項:x.choice_label,選項票數:Number(x.votes),
   投票人數:Number(x.total_ballots),名冊人數:Number(x.eligible_count)})),'ClassPoll-正式表決-'+activeResult.id.slice(0,8));
}
function wire(){
 $('loginForm').addEventListener('submit',signIn);$('logoutBtn').addEventListener('click',signOut);
 $('refreshBtn').addEventListener('click',loadRooms);
 $('roomSelect').addEventListener('change',e=>{roomId=e.target.value;resetEditor();show('resultSection',false);activeResult=null;void loadBallots();});
 $('ballotMode').addEventListener('change',updateMode);
 $('startNow').addEventListener('change',e=>{$('startsAt').disabled=e.target.checked;});
 $('createForm').addEventListener('submit',createBallot);$('cancelEdit').addEventListener('click',resetEditor);
 $('ballotList').addEventListener('click',handleAction);
 $('exportResult').addEventListener('click',exportResults);
 $('hideResult').addEventListener('click',()=>show('resultSection',false));
 document.addEventListener('visibilitychange',()=>{if(!document.hidden&&authorized)void loadBallots();});
 setInterval(()=>{if(authorized&&!document.hidden)void loadBallots();},20000);
}
window.addEventListener('load',async()=>{
 initDates();updateMode();wire();if(!guardConfig())return;
 db=client('teacher');if(!db)return;
 try{
  await verify();
  db.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT'){authorized=false;user=null;rooms=[];roomId='';ballots=[];loadedResults=[];show('resultSection',false);authView();}});
 }catch(e){failure(e,'初始化失敗');}
});

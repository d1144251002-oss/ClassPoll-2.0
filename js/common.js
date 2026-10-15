import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from './config.js';

// A placeholder key or a REST endpoint path must never be treated as
// a working Supabase SDK configuration.
const validProjectUrl = (() => {
  try {
    const url = new URL(SUPABASE_URL);
    return url.protocol === 'https:' && !!url.hostname &&
      url.pathname === '/' && !url.search && !url.hash &&
      !url.hostname.includes('YOUR-PROJECT');
  } catch { return false; }
})();
const validPublishableKey = /^sb_publishable_[A-Za-z0-9_-]{20,}$/.test(SUPABASE_PUBLISHABLE_KEY);
export const configured = validProjectUrl && validPublishableKey;
export const supaReady = () => typeof window.supabase?.createClient === 'function';
export function client(role) {
  if (!configured || !supaReady()) return null;
  return window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
    auth: { storageKey: `classpoll-2-${role}-session`, persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
    realtime: { params: { eventsPerSecond: 15 } }
  });
}
export const $ = (id) => document.getElementById(id);
export const txt = (id, value) => { const n=$(id); if(n) n.textContent=String(value ?? ''); };
export const show = (id, visible=true) => { const n=$(id); if(n) n.classList.toggle('hidden',!visible); };
export const escapeHtml = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function toast(message, isError=false) {
  const area=$('toasts'); if(!area) { window.alert(message); return; }
  const node=document.createElement('div');node.className='toast '+(isError?'error':'');node.textContent=message;
  area.appendChild(node); setTimeout(()=>node.remove(),5500);
}
let errorReporter=null;
export function setErrorReporter(db,scope,getRoomId){
 errorReporter=async (message)=>{
   if(!db)return;
   // Do not upload raw request payloads, passwords, access codes or stack traces.
   const sanitized=String(message).replace(/[\w.+-]+@[\w.-]+/g,'[email]').replace(/\b[a-fA-F0-9]{32,}\b/g,'[token]').slice(0,500);
   const room=getRoomId?.()||null;
   try {await db.rpc('cp2_log_error',{p_room:room,p_scope:scope,p_message:sanitized});}catch(e){console.warn('錯誤監測同步失敗',e);}
 };
}
export function failure(error, prefix='操作失敗') {
 console.error(prefix,error);toast(`${prefix}：${error?.message || String(error)}`,true);
 errorReporter?.(`${prefix}：${error?.message || String(error)}`);
}
export function setBusy(button, busy, label) {
  if (!button) return; if(!button.dataset.label) button.dataset.label=button.textContent;
  button.disabled=busy;button.textContent=busy?(label||'處理中…'):button.dataset.label;
}
export const fmtDate=(v)=>v?new Date(v).toLocaleString('zh-TW',{hour12:false}):'—';
export const timeLeft=(v)=> v? Math.max(0, Math.ceil((new Date(v).getTime()-Date.now())/1000)):null;
export const asOptions = (x) => Array.isArray(x)? x : (typeof x==='string'? JSON.parse(x): []);
export async function query(promise) {const {data,error}=await promise; if(error) throw error;return data;}
export async function rpc(db, name, args) {return query(db.rpc(name,args));}
export function dl(name, contents, type='text/csv;charset=utf-8') {
 const blob=new Blob([contents],{type}); const href=URL.createObjectURL(blob);
 const a=document.createElement('a');a.href=href;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(href),3000);
}
export function exportRows(rows, basename='classpoll-report') {
 const keys=[...new Set(rows.flatMap(o=>Object.keys(o)))];
 // Neutralize spreadsheet formula injection in names, questions and free text.
 const safe = (value) => typeof value==='string' && /^[=+@-]/.test(value.trimStart()) ? '\''+value : value;
 const cleanRows=rows.map(row=>Object.fromEntries(keys.map(k=>[k,safe(row[k])])));
 if(!keys.length) {toast('尚無可匯出的資料',true);return;}
 if(window.XLSX?.utils) {
   const sheet=window.XLSX.utils.json_to_sheet(cleanRows,{header:keys});
   const book=window.XLSX.utils.book_new();window.XLSX.utils.book_append_sheet(book,sheet,'報表');
   window.XLSX.writeFile(book,basename+'.xlsx');
 } else {
   const quote=v=>'"'+String(v??'').replace(/"/g,'""')+'"';
   dl(basename+'.csv','\uFEFF'+[keys.join(','),...cleanRows.map(r=>keys.map(k=>quote(r[k])).join(','))].join('\r\n'));
   toast('Excel 元件未載入，已改用 Excel 可開啟的 CSV');
 }
}
export function initials(name) {return (name||'CP').slice(0,2).toUpperCase();}
export function localLink(page, roomCode='') {
 const url=new URL(page,location.href);if(roomCode)url.searchParams.set('room',roomCode);return url.href;
}
export function guardConfig() {
 if(configured&&supaReady())return true;
 show('configNotice'); return false;
}
export function listenReconnect(refresh) {
 window.addEventListener('online',()=>{toast('網路已恢復，正在補同步');refresh();});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
}

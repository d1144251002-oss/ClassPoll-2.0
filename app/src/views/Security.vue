<script setup lang="ts">
import {onMounted,ref,computed} from 'vue';
import {db,rpc,typedError} from '../services/api';
import {session,flash} from '../services/session';
type Staff={email:string;role:string;appointed_on:string};
const members=ref<Staff[]>([]),email=ref(''),role=ref('teacher'),error=ref('');
const isAdmin=computed(()=>session.staffRole==='admin');
const labels:Record<string,string>={admin:'系統管理員',registrar:'教務管理人員',teacher:'教師',auditor:'稽核人員'};
async function load(){
 if(!['admin','registrar'].includes(session.staffRole))return;
 try{members.value=await rpc<Staff[]>(db(),'cp3_staff_list')}catch(e){error.value=typedError(e)}
}
async function grant(){
 if(!isAdmin.value)return;
 if(!confirm('確定要更改此 Auth 帳號的全校管理權限？所有調整均留下稽核紀錄。'))return;
 try{await rpc(db(),'cp3_staff_set',{p_email:email.value,p_role:role.value});flash('校級角色已更新');email.value='';await load()}
 catch(e){error.value=typedError(e)}
}
onMounted(load);
</script>
<template>
 <div class="page-heading"><div><span class="eyebrow">CAMPUS SECURITY</span><h1>身分權限與安全治理</h1><p class="muted">校級權限由後端 RPC 與 RLS 控制，前端顯示不是授權依據。</p></div><button class="outline" @click="load">重新整理</button></div>
 <div v-if="error" class="alert error">{{error}}</div>
 <div class="cards" style="margin-bottom:20px">
  <div class="card"><small>本人校園角色</small><strong class="number" style="font-size:19px">{{labels[session.staffRole]||'教職員'}}</strong></div>
  <div class="card"><small>身分驗證</small><strong class="number" style="font-size:20px">Supabase Auth</strong></div>
  <div class="card"><small>資料權限</small><strong class="number" style="font-size:20px">RLS + RPC</strong></div>
  <div class="card"><small>個人資訊</small><strong class="number" style="font-size:20px">不得共用</strong></div>
 </div>
 <div class="grid-2">
  <form v-if="isAdmin" class="panel stack" @submit.prevent="grant">
   <h2>新增／變更校園教職員</h2>
   <p class="muted">必須先由管理員在 Supabase Auth 建立真實帳號；此介面只授權既有帳號，不能在公開前端建立 Auth 使用者。</p>
   <label>Email<input v-model.trim="email" type="email" required/></label>
   <label>校級角色<select v-model="role"><option value="admin">系統管理員</option><option value="registrar">教務管理人員</option><option value="teacher">教師</option><option value="auditor">稽核員</option><option value="remove">撤銷校級授權</option></select></label>
   <button class="primary" type="submit">確認角色變更</button>
  </form>
  <section class="panel"><h2>安全設定與待完成整合</h2>
   <p class="muted">以下設定需要校方與 Supabase 專案管理權限，無法由一般校園網頁直接操作：</p>
   <p>• 教師 MFA、外洩密碼防護與登入限流</p>
   <p>• 校方核准的 SAML／OIDC 身分供應商與 SSO</p>
   <p>• 資料庫自動備份、PITR、跨環境還原演練</p>
   <p>• 受監控的錯誤日誌、API 延遲與事故通報</p>
   <p>• 校方正式伺服器上的 CSP、HSTS、WAF 及 TLS</p>
  </section>
 </div>
 <section v-if="['admin','registrar'].includes(session.staffRole)" class="panel" style="margin-top:20px">
  <h2>已授權校級管理人員</h2>
  <div v-if="!members.length" class="empty">沒有可讀取的授權人員清單。</div>
  <div v-else class="table-wrap"><table><thead><tr><th>Email</th><th>角色</th><th>授權日期</th></tr></thead><tbody>
   <tr v-for="m in members" :key="m.email"><td>{{m.email}}</td><td>{{labels[m.role]||m.role}}</td><td>{{new Date(m.appointed_on).toLocaleString('zh-TW')}}</td></tr>
  </tbody></table></div>
 </section>
</template>

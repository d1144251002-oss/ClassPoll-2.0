import {computed,ref} from 'vue';
import {createClient,type SupabaseClient,type User} from '@supabase/supabase-js';

export type AppRole='teacher'|'student'|'none';
const url=import.meta.env.VITE_SUPABASE_URL;
const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
export const configured=Boolean(url?.startsWith('https://')&&key?.startsWith('sb_publishable_'));
export const supabase:SupabaseClient|null=configured?
 createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:false}}):null;
export const currentUser=ref<User|null>(null);
export const role=ref<AppRole>('none');
export const initializing=ref(true);
export const signedIn=computed(()=>role.value!=='none');
let authGeneration=0;
async function determineRole(user:User|null) {
 const current=++authGeneration;
 currentUser.value=user;
 if(!user){role.value='none';return;}
 if(user.is_anonymous){role.value='student';return;}
 if(!supabase){role.value='none';return;}
 const {data,error}=await supabase.from('cp2_teachers').select('user_id').eq('user_id',user.id).maybeSingle();
 if(current!==authGeneration)return;
 role.value=!error&&data?'teacher':'none';
}
export async function initializeSession(){
 if(!supabase){initializing.value=false;return;}
 try{
  const {data,error}=await supabase.auth.getSession();
  if(error)throw error;
  await determineRole(data.session?.user??null);
  supabase.auth.onAuthStateChange((_event,session)=>{void determineRole(session?.user??null);});
 }finally{initializing.value=false;}
}
export async function loginTeacher(email:string,password:string){
 if(!supabase)throw Error('尚未配置安全的資料服務');
 const {data,error}=await supabase.auth.signInWithPassword({email:email.trim(),password});
 if(error)throw error;
 await determineRole(data.user);
 if(role.value!=='teacher')throw Error('此帳號尚未取得授權教師權限');
}
export async function logout(){
 if(!supabase)return;
 const {error}=await supabase.auth.signOut();
 if(error)throw error;
 await determineRole(null);
}

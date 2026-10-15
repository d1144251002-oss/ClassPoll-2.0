import {createClient,type SupabaseClient} from '@supabase/supabase-js';
import {SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY} from '../../../js/config.js';

const defaults={persistSession:true,autoRefreshToken:true,detectSessionInUrl:false};
export const teacherApi:SupabaseClient=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{
 auth:{...defaults,storageKey:'classpoll-2-teacher-session'}
});
export const studentApi:SupabaseClient=createClient(SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,{
 auth:{...defaults,storageKey:'classpoll-2-student-session'}
});
export function typedError(error:unknown):string {
 if(error instanceof Error)return error.message;
 if(typeof error==='object'&&error!==null&&'message' in error)return String(error.message);
 return '操作失敗，請稍後重試';
}
export async function rpc<T=unknown>(db:SupabaseClient,method:string,args:Record<string,unknown>={}):Promise<T>{
 const {data,error}=await db.rpc(method,args);
 if(error)throw error;
 return data as T;
}

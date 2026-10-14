/**
 * ★ 唯一需要填寫的 Supabase API 設定檔 ★
 * Supabase Dashboard → Project Settings → API Keys / Connect
 * 只允許 Publishable key (sb_publishable_...)；絕對不可放 Secret / service_role key。
 * 靜態 GitHub Pages 網頁的此檔是公開的，所以資料保護全部依靠 RLS。
 */
export const SUPABASE_URL = 'https://mexndpdexhhqshcwyqxk.supabase.co/rest/v1/';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_你的公開金鑰';

// 可自行修改品牌名稱，不影響資料庫。
export const APP_NAME = 'ClassPoll 2.0';

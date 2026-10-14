# ClassPoll 2.0：Supabase API 放置位置與安裝教學

## 01. 填寫 Supabase API —— 只改 `js/config.js`

開啟 `js/config.js`，找到：

```js
export const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_REPLACE_ME';
```

登入 https://supabase.com/dashboard → 進入專案 → 按 **Connect** 或 **Project Settings → API Keys**。

| 欄位 | 從 Supabase 複製哪個值 | 範例 |
|---|---|---|
| `SUPABASE_URL` | Project URL | `https://abcxyz.supabase.co` |
| `SUPABASE_PUBLISHABLE_KEY` | Publishable Key | `sb_publishable_xxxxx...` |

注意：**只放 Publishable Key**，絕對禁止放 `sb_secret_*`、`service_role`、SQL 密碼！前端設定會公開給任何瀏覽器使用者，因此所有資料保護都靠 RLS 和 RPC 伺服器驗證。

## 02. 安裝 Supabase 資料庫與安全規則

Supabase Dashboard → 左側 **SQL Editor** → New query → 複製 `supabase/01_install.sql` 的**全文** → **Run**。

這支 SQL 建立：

- 角色、教室、學生名冊、題庫、題目、正確答案、投票、出席、稽核與錯誤記錄 `cp2_*` 表。
- 所有公開資料表的 Row Level Security，撤銷不必要的資料表操作權限。
- 教師限定 RPC、學生邀請碼與身分綁定、安全投票、一次性入班碼重新簽發等功能。
- 啟用 `cp2_questions`、`cp2_votes` 的 Supabase Realtime Postgres Changes。

如 SQL Editor 報錯，請先停下並保留**完整錯誤訊息與行號**。不可只把 RLS 關閉或把所有資料表授權 `anon` 來繞過錯誤。

## 03. 開啟教師與學生驗證

Supabase Dashboard → Authentication → Providers / Sign In：

1. **Email**：教師必須可以用 Email + 密碼登入；若開啟 Email 驗證，請完成驗證。
2. **Anonymous Sign-Ins**：啟用，學生使用匿名 Supabase Auth，再透過個人入班碼完成名冊綁定。
3. 部署到 GitHub Pages 後，將實際網址新增到 Authentication → URL Configuration 允許的 redirect URLs（本版使用 Email + Password 與匿名驗證，通常不需經 Redirect 但預先設定可供未來擴充）。

## 04. 設定真正教師（不可使用前端註冊立即當教師）

Dashboard → Authentication → Users → **Add user** 建立教師帳號。接著打開 `supabase/02_grant_teacher.sql`，把：

```
REPLACE_WITH_TEACHER_EMAIL@example.edu
```

改成真正的教師信箱（SQL 內共出現兩次），再於 SQL Editor 執行。

範例：

```sql
insert into public.cp2_teachers (user_id, label)
select id, '授課教師' from auth.users
where email = 'teacher@your-school.edu'
  and (is_anonymous is distinct from true)
on conflict (user_id) do update set label=excluded.label;
```

這項操作只可由資料庫管理員執行，**不能寫在前端 JavaScript**。

## 05. 部署 GitHub Pages

建議建立新儲存庫 `classpoll-2`；把 `index.html`、`teacher.html`、`student.html`、`js`、`assets` 等檔案放在根目錄。

GitHub repository → **Settings → Pages → Build and deployment**：

- Source：`Deploy from a branch`
- Branch：`main`
- Folder：`/(root)`

例如 GitHub Pages 最終網址類似：`https://YOUR-GITHUB-NAME.github.io/classpoll-2/`。

開啟首頁 → 教師端 → 登入 → 建立教室 → 新增學生 → 發放個人入班碼 → 發題。學生使用教師複製的學生網址進入；網址內**只帶教室代碼，不含學生個人入班碼**。

## 06. 正式上線檢查

在 Supabase SQL Editor 確認資料表是否存在：

```sql
select table_name from information_schema.tables
where table_schema='public' and table_name like 'cp2_%'
order by table_name;
```

檢查 RLS：

```sql
select schemaname,tablename,rowsecurity from pg_tables
where schemaname='public' and tablename like 'cp2_%';
```

檢查 Realtime：

```sql
select schemaname,tablename from pg_publication_tables
where pubname='supabase_realtime' and tablename in ('cp2_questions','cp2_votes');
```

RLS 欄位應都是 `true`；Realtime 應查到這兩張表。

## 07. 常見錯誤

- `Anonymous sign-ins are disabled`：至 Authentication → Providers 開啟匿名登入。
- `permission denied for table cp2_*`：確認 SQL 全部執行，角色授權、RLS、函式 EXECUTE 正常；不可單純關閉 RLS。
- `function cp2_join(...) does not exist`：SQL 安裝未完整完成，或 RPC PostgREST Schema Cache 尚未重新整理。確認函式簽名。
- 教師登入後顯示沒有權限：請確認 `02_grant_teacher.sql` 最後有回傳一筆，且登入 Email 正確。
- 學生提示「學號已綁定另一裝置」：教師於學生名冊按「重設入班碼」，新碼發送給學生；歷史票數保留。
- 只有某些人收不到即時事件：先確認 RLS 與 Realtime publication；本系統會定期補同步，但不能假設 Socket 一直暢通。
- GitHub Pages 白畫面：檢查 `js/config.js` 與開發工具 Console，確認靜態檔案已放在正確目錄，不能直接用 `file://` 開啟。

## 08. 既有 ClassPoll 資料處理

新版刻意使用 `cp2_*` 資料表，不破壞舊版 `classrooms` / `questions` / `votes`。舊教室及投票紀錄**不會自動搬過來**。需要移轉時，先備份舊表，並針對欄位映射、匿名 UID 與成績保留另行製作一次性遷移程序。

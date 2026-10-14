# ClassPoll 2.0 — 大學課堂即時投票／測驗平台

> 2026-10-14 製作的**可部署原始碼**。採用純 HTML/CSS/ES Modules + Supabase，不需要 npm / Node.js / 自架伺服器，適合部署到 GitHub Pages。**並未直接修改原始 GitHub 儲存庫，也尚未在真實 Supabase 上完成端對端驗收。**

## 你要找的 Supabase API 位置

**`js/config.js`** 是唯一放置前端 Supabase API 連線資訊的檔案：

```js
export const SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_REPLACE_ME';
```

Supabase Dashboard → **Connect** 或 **Project Settings → API Keys** 複製 Project URL 和 **Publishable key (`sb_publishable_…`)**。

**嚴禁**把 `sb_secret_…`、`service_role`、資料庫連線密碼放進 JavaScript、GitHub 儲存庫或學生能看到的檔案。前端 Publishable key 是公開資料，實際授權完全依賴 RLS。

請參考 [`SUPABASE_SETUP.md`](SUPABASE_SETUP.md) 的完整安裝步驟。

## 專案目錄

```text
classpoll-2/
├── index.html                   共用入口
├── teacher.html                 教師控制台
├── student.html                 學生手機版答題介面
├── assets/style.css             共用 RWD 設計系統
├── js/
│   ├── config.js                ★ Supabase URL + Publishable Key 填這裡
│   ├── common.js                共用 API、輸出、錯誤追蹤
│   ├── teacher.js               教師權限/題庫/投票/分析
│   └── student.js               匿名驗證/綁定/斷線重同步
├── supabase/
│   ├── 01_install.sql           資料表/索引/RLS/安全函式/Realtime
│   └── 02_grant_teacher.sql     ★ 管理員授予教師權限
├── SUPABASE_SETUP.md            安裝與部署教學
└── TESTING.md                   驗收檢查與安全限制
```

## 已實作功能（非模擬展示）

- P0：教師身分由 `cp2_teachers` 白名單管理，教師操作依資料庫政策限制於所管理教室。
- P0：學生必須先由教師建立於名冊，利用 128-bit 隨機個人入班碼加入（資料庫僅儲存 SHA-256 雜湊）。學生匿名 Supabase Auth ID 與學生名冊記錄綁定；重新發碼由教師操作。
- P0：投票寫入透過經伺服器核對身分、教室、截止時間及題目狀態的 SQL RPC。資料庫 `(question_id, student_id)` 唯一鍵防止重複寫入；教師可設定是否容許修改已提交答案。
- P0：Realtime 訂閱 + 學生每 15 秒補同步 + 教師每 20 秒補同步 + 視窗重新顯示 / 上線事件重新讀取；提交後再查資料庫確認。
- P1：教師首頁儀表板、投票分布圖、教室新增與停用、複製教室連結與 QR Code。
- P1：單筆或批次建立學生、一次性產生私密入班碼、停用/重新簽發入班碼、出席紀錄、近兩分鐘在線狀態。
- P1：題庫 CRUD、題目分類、標準答案、配分、30 秒等限時測驗（最高 7200 秒）、逐題發布/結束。
- P2：歷史題目與學生分數、逐題答對率、完整作答明細、出席/個人入班碼匯出 Excel（CDN 可用時 `.xlsx`；不可用則 `.csv`）。
- P2：功能模組化、UI 自適應桌機與手機、教師操作稽核、限流的前端錯誤摘要回報。

## 安裝速覽

1. 在你自己的 Supabase 專案打開 **SQL Editor**，執行 `supabase/01_install.sql`。
2. Authentication → Providers → **Email**：允許教師電子郵件/密碼登入；Authentication → Providers → **Anonymous Sign-Ins**：開啟學生匿名登入（位置可能隨 Dashboard 版本而異）。
3. Authentication → Users：建立教師 Email/Password 帳號。編輯 `supabase/02_grant_teacher.sql` 內的教師信箱，在 SQL Editor 執行，並確認最後的 SELECT 有一筆。
4. 編輯 `js/config.js`，填入 Supabase Project URL / Publishable key。**不要使用 Secret Key**。
5. 將整個資料夾的**內容**上傳至 GitHub 儲存庫根目錄，在 Settings → Pages → `Deploy from a branch` → `main` / `(root)` 開啟網站。
6. 進教師端登入 → 建立教室 → 建立學生名冊 → 匯出並安全發放入班碼 → 建立/發布題目 → 學生完成作答。

本機瀏覽開發版：進入專案資料夾，執行 `python -m http.server 8000`，開啟 `http://localhost:8000`。不要直接用 `file://`，ES Modules 可能受瀏覽器安全限制。

## 與你原始專案的關係

原始專案 `teacher0001` 與 `lll` 的 HTML 已經使用相同 Supabase Project，但沒有一致完整的使用者驗證模型。本次提供的是**完整重建的 ClassPoll 2.0**，並非只把兩頁 iframe 串在一起。為了**避免覆蓋原有資料**，新系統會建立全新 `cp2_*` 資料表。原始的 `classrooms`, `questions`, `votes` **不會自動匯入**；若要遷移舊資料，需要進一步根據舊資料表結構及清洗結果建立遷移程式，請先備份。

## 技術注意事項

- GitHub Pages 是靜態託管；安全函式、唯一限制及所有 RLS 都在 Supabase PostgreSQL 執行。
- `teacher` 與 `student` 各自使用獨立 Supabase Auth localStorage key，避免同一網站上的兩種身分互相覆寫。
- 參與必須持有個人入班碼；這提高冒用門檻，但**仍不等同校方 SSO 學生身分驗證**。如果學生主動洩露邀請碼，尚未綁定時可能被別人搶先使用。正式記分或學校成績建議改接校方 SSO / 正式帳號驗證。
- 清除瀏覽器資料 / 換裝置將失去學生匿名登入身分；教師可透過「重設入班碼」重新簽發代碼，已儲存的票數與分數保留。
- Realtime 並不保證每個事件 100% 到達，因此以週期補讀資料庫作為最終一致性的保障。
- 教師必須妥善保存 `.xlsx/.csv` 裡的個人入班碼；匯出檔為敏感資料，請勿放進公開 GitHub。
- 重要故障與權限錯誤應透過 Supabase Dashboard 的 Database Logs / Auth Logs 追蹤；系統內建的錯誤摘要僅供輔助，不能代替專業 APM。

## 官方參考資料

- [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase Anonymous Sign-ins](https://supabase.com/docs/guides/auth/auth-anonymous)
- [Supabase API Keys](https://supabase.com/docs/guides/getting-started/api-keys)
- [Supabase Realtime / Postgres Changes](https://supabase.com/docs/guides/realtime/subscribing-to-database-changes)

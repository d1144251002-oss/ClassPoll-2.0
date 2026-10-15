# 龍華科技大學 ClassPoll 校園伺服器部署與資料庫搬遷手冊

本文件供龍華科技大學網路與系統管理、資訊安全、資料庫管理及授課教師共同評估與交接。**目前的 GitHub Pages 上線不等於已在校方伺服器正式啟用**；正式校網域、服務核准及校內資料處理需由校方權責單位決定。

## A. 搬遷前決策表

| 項目 | 模式 A：只遷移網站 | 模式 B：所有服務遷校內 |
|---|---|---|
| 靜態入口／工作台 | 校內 HTTPS 網站 | 校內 HTTPS 網站 |
| PostgreSQL | 繼續使用原 Supabase Project | 校內 PostgreSQL，需 DBA 搬遷 |
| Auth、匿名學生身分 | 原 Supabase Auth | 自建 Supabase 相容 Auth |
| PostgREST RPC、RLS | 原 Supabase | 需自行安裝、管理並測試 |
| Realtime | 原 Supabase | 需自行建置且保證 WebSocket/TLS |
| 工作量／維運風險 | 相對較低 | 高，涉及資安、備份、密鑰輪替 |
| 校內資料留存 | **不成立**，資料仍在原 Supabase | 視校內部署及備份位置而定 |

部署選擇須先由校方資安／個資權責人確認資料分類、角色、保存年限、營運責任、所需認證及正式服務名稱。沒有校方核准時，不得擅自接入校務身分、教學成績系統或使用校方正式商標／印章。

## B. 模式 A：只搬靜態檔到龍華科技大學 HTTPS 主機

### B1. 必要環境

- 具正式核准的 FQDN，例如 `<由校方核定的主機名稱>`，及由校方管理的 TLS 憑證。
- Nginx／Apache 或其他可信任的靜態檔案服務；HTTPS 443 允許外部連接。
- 連到原 Supabase API 的 HTTPS、WebSocket 的 WSS，及學校網路政策允許的 CDN 網域；若封鎖公共 CDN，須依授權政策自行鏡像對應 JavaScript 相依套件並更新 HTML。
- 校內備份與發布管線；建議 Git Tag + 版本檔、可回退的靜態內容版本。

### B2. 搬遷來源檔案

從經驗收的 GitHub `main` 專案取檔（不可把 `.git` 或資料庫密碼同步到網站根目錄）；根目錄應包含：

```text
index.html
admin.html
teacher.html
student.html
ballots.html
vote.html
assets/
js/
```

將上述項目置於校內網站根目錄（例如 `/var/www/classpoll2`）。**若部署子路徑** `/classpoll/`，請確保所有路徑仍保持相對引用且首頁能找到 `index.html`，邀請連結會依當前網址產生。

### B3. Nginx 範例（由校方管理員調整）

```nginx
server {
    listen 443 ssl http2;
    server_name <由校方核定的主機名稱>;
    root /var/www/classpoll2;
    index index.html;
    autoindex off;

    ssl_certificate     /path/to/school-managed-fullchain.pem;
    ssl_certificate_key /path/to/school-managed-private-key.pem;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location / {
        try_files $uri $uri/ =404;
    }
    location = /js/config.js {
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        try_files $uri =404;
    }
    location ~ /\.(?!well-known) {
        deny all;
    }
}
```

> 範例不包含校方既有反向代理、WAF、監控及自動憑證管理；須通過 `nginx -t` 且不得暴露 TLS 私鑰。若使用 HSTS，請由負責 HTTPS 全網域的單位評估後開啟。

若使用前端子路徑，建議建立獨立 vhost／subdomain 或在正式上線前核對相對 URL 與防快取策略，避免錯誤改寫導致模組及 JS 404。

### B4. Supabase 設定與連線

1. `js/config.js` 指向原 Project URL 和公開 `sb_publishable_...`，絕不可放入 `service_role`／`sb_secret_`／資料庫帳密。
2. Supabase Authentication 設定與校方網站一致的 Site URL 和允許的 Redirect URLs（若未使用 OTP／SSO，仍要確認 Auth 設定）。學生 Anonymous Sign-ins 與教師 Email 登入均需維持啟用。
3. 檢查校內 DNS、HTTPS、Supabase Auth 服務是否可訪問；若校方代理／WAF 有跨來源規則，請確認允許必要的 PostgREST API 和 WebSocket。
4. 實際使用不同瀏覽器測試登入、建立教室、匿名入班、出席、測驗、問答及結果匯出。
5. 切換舊網址前先通知教師：舊 QR Code 和已產生的邀請網址可能仍指向 GitHub Pages。若要統一入口，請安排永久轉址與過渡期；不要突然停用正使用中的網址。

**注意**：模式 A 的資料仍在原有 Supabase 雲端專案，不可對外宣稱「資料庫已經移轉至龍華校內」。

## C. 模式 B：完整移轉 PostgreSQL、Auth、PostgREST、Realtime

這不是靜態網站改連新 IP 就可完成的工程。需要 Supabase 對應的服務組件、校方平台維護者、DBA、備份、資安審核與停機時段。

### C1. 服務依賴

```text
Public TLS / WAF / reverse proxy
    ├─ Static portal (index.html, teacher.html, ...)
    └─ Supabase-compatible gateway
        ├─ Auth (Email + Anonymous / JWT)
        ├─ PostgREST (public RPC, RLS)
        ├─ Realtime (WebSocket, postgres_changes)
        ├─ PostgreSQL (extensions, schemas, roles, constraints, policies)
        └─ Backup / logs / monitoring / secret manager
```

資料庫中 `auth.users` 綁定 `cp2_teachers.user_id`、`cp2_students.auth_uid`，必須保持 UUID、Auth 和簽發 JWT 的一致性。**僅匯出 public schema 或只匯入 cp2_* 表會破壞登入與學生身分綁定**。

### C2. 搬遷順序（由 DBA 核准）

1. **盤點現況**：PostgreSQL 版本、Supabase Auth／PostgREST／Realtime、extensions（包含 pgcrypto）、資料量、公開／私有 schema、RLS／GRANT、索引、函式、Triggers、Realtime publication、資料留存。
2. **全量備份**：採 Supabase 官方資料庫備份/PITR 或由授權 DBA 使用正確版本 `pg_dump`／`pg_restore`；備份需包含 Auth／public 的完整關聯資料、schema／函式／角色與必要設定。加密並保管備份金鑰，先進行**還原演練**。
3. **建立平行校內環境**：部署經校方資安審查且版本相容的 Supabase 自架服務組合（不能僅啟動 PostgreSQL）；所有 API／Auth／Realtime 先使用測試 DNS 和非正式身分。
4. **復原到驗證環境**：以官方工具或 DBA 規劃的 schema 與資料搬遷方式復原，處理管理角色映射、extensions、服務依賴、JWT/驗證金鑰、SMTP、RLS/GRANT、學生匿名工作階段與 Realtime publication。不得隨意將舊系統 service_role 或 JWT Secret 暴露至前端。
5. **核對資料完整性**：逐表數量、主鍵唯一性、外鍵完整性、Auth UUID、教師權限、歷史票數與成績、出席、校園表決分離保護；驗證 SHA/雜湊與學生身份綁定能在預期方式恢復。
6. **授權安全測試**：獨立教師可只存取自身班級、稽核員唯讀、學生只能查看自身問答、截止後作答受阻、表決結果門檻執行、直接查詢 `cp2_ballot_choices` 被禁止。
7. **資料切換**：排定停機或唯讀窗口，關閉舊站的新寫入、取得最終一致快照、補上期間變更、切換 `js/config.js` 的 Project URL 和 Publishable Key、公開新版本。確認舊學生 Auth Session 的兼容性，必要時安排重新入班或由教師重新發碼。
8. **上線後監控**：登入錯誤、PostgREST 4xx/5xx、Realtime 斷線、DB 連線池、備份完成、磁碟／CPU、稽核異常；留有明確回退時限。

### C3. 危險事項

- 若只使用 `pg_dump -n public`，**不會包含** Auth 使用者、設定等必要資料；也不能保證 Realtime／storage／憑證一致。
- 無論怎麼搬遷，都不能把 Supabase `sb_secret_`、service_role、DB Password、JWT Secret 直接寫入瀏覽器程式；這些只能留在受控服務端。
- 既有學生匿名 Auth 工作階段與裝置相關，切換簽發者／JWT Secret 時可能失效。請由校方在遷移計畫中明訂身分銜接與重設入班碼的程序。
- **資料備份不等於資料恢復**：須能在校內隔離環境真的完成還原演練、驗證分數和 Auth 一致，才可視為具備災難復原能力。

## D. 全新 Supabase 安裝與既有專案升級

### 全新、沒有資料的 Project

按專案版本審核：

1. `supabase/01_install.sql` 安裝基礎 schema。
2. 比對 `supabase/03_fix_rooms_rls.sql`、`04_performance_indexes.sql`、`05_fix_vote_deadline.sql`、`06_join_error_privacy.sql` 和 01 的實際定義；按需套用，切勿不經比較重新覆蓋已修補函式。
3. 執行 `07_governance_ballots.sql` → `08_ballot_draft_update.sql` → `09_platform_core.sql` → `10_classroom_qna.sql`。
4. Supabase Auth 啟用 Email 與匿名登入；設定密碼強度、MFA（教師優先）、Leaked Password Protection、登入限流、郵件 SMTP 和適當的 Site URL。
5. 在 Auth Users 建立教師帳號，修改 `02_grant_teacher.sql` 的 Email，執行後確認存在於 `cp2_teachers`。
6. 配置 `js/config.js` 的公開 Project URL／Publishable Key，測試讀寫權限。

### 現有 Project（有學生和教室資料）

- 先完整備份，查詢已套用的 migration version，依實際資料庫狀態決定是否新增 DDL；不可對現有使用中的 `cp2_*` 執行刪除重建。
- 教師白名單、正式票數、匿名學生 Auth UID 必須保留。測試資料採交易 `BEGIN ... ROLLBACK` 或獨立測試環境，避免污染正式投票。
- 所有 `SECURITY DEFINER`、`search_path`、函式執行權、RLS 及 `anon/authenticated` 的 GRANT 都必須逐一驗證。

## E. 驗收清單／正式發布門檻

- [ ] 校方確定服務名稱、校內正式網域、資安及個資權責單位。
- [ ] HTTPS 憑證、TLS、DNS、校內 WAF、WebSocket / REST API 通路通過。
- [ ] 正確配置 Supabase Project URL、公開金鑰和 Auth URL；未暴露秘密。
- [ ] 確認 Email 教師登入、白名單、教室 owner／assistant／auditor RLS。
- [ ] 學生入班、匿名 Auth、同班出席、裝置重綁及停用學生驗證。
- [ ] 題庫新增／修改、限時答題、重新整理、斷線恢復、教師結束題目。
- [ ] 問答保密、學生提交、教師回覆、每小時限流、跨教室隔離。
- [ ] 學生個資、成績、出席與表決紀錄匯出，CSV/XLSX 檢查無公式注入。
- [ ] 加密備份／錯誤密碼拒絕／僅重建名冊的限制經使用者確認。
- [ ] 已跑過 GitHub 品質、PostgreSQL RLS、Chromium UI、公開網站 Smoke Test。
- [ ] 完成真正跨帳號／高負載情境驗收，以及資料庫**完整**還原演練。
- [ ] 正式版確認無殘留開發測試標籤、QA 教室或測試帳號。
- [ ] 監控、備份、事故通報、資料留存及回退負責人已指派。

## F. 上線故障與回退

1. 只發生前端 UI 問題：透過版本化靜態目錄和 Git Tag／Commit 回退到上一版，保留向後相容的 Supabase schema；不要破壞既存作答。
2. API 或 Auth 無法使用：先確認 Supabase project、RLS/GRANT、匿名登入、許可網域、CORS、WebSocket，保留日誌後由管理員修復。
3. PostgreSQL 資料損毀：停寫、保全現場、由 DBA 根據演練過的正式備份／PITR 還原並核對資料完整性。**不可使用刪除表格取代資料復原**。
4. 事件後重新執行雙身分 E2E、比較成績、出席與正式票數，經核准後恢復寫入。

## G. 維護責任建議

| 職責 | 權責 |
|---|---|
| 校方系統管理員 | 伺服器、網域、TLS、GitHub 發版、運作監控 |
| 資安／個資管理單位 | 帳號政策、MFA、個資告知、漏洞管理、稽核 |
| DBA／Supabase 管理員 | SQL Migration、Auth/RLS、備份、資料復原 |
| 授課教師／教室擁有者 | 班級、學生、入班碼及題目／報表 |
| 協作助理／稽核員 | 僅在獲授權的教室查看資料，不得越權修改 |
| 學生 | 保管個人入班碼、使用自己的教室身分作答 |

其他資料：`README.md`、`SUPABASE_SETUP.md`、`PLATFORM_RELEASE.md`、`GOVERNANCE_BALLOTS.md`。

## 給校方核准者的最後提醒

本專案目前使用「龍華科技大學」的校園主題文字，不代表已取得校方正式核准；既有後端仍為原 Supabase Project。正式上線時應以學校核准的服務識別、校內伺服器及資料保護政策為準。自動化測試通過並不能保證沒有任何 BUG。

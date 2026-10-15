# ClassPoll 2.0 測試與交付範圍

## 2026-10-15 上線驗收更新（以實際執行結果為準）

### 已經驗證
- Supabase 正式專案 `mexndpdexhhqshcwyqxk` 的 10 張 `cp2_*` 表皆有 RLS，教師角色已綁定。
- 同一個教師 Auth 帳號在受 RLS 的 SQL 交易中使用 `INSERT ... RETURNING` 建立教室成功。修正：`supabase/03_fix_rooms_rls.sql`（新安裝已同步至 `01_install.sql`）。
- 以 PostgreSQL 模擬已驗證的 teacher / anonymous JWT claims，成功依序建立教室、學生、發布題目、入班、投票及讀回投票。
- 錯誤入班碼、重複投票、學生呼叫教師 RPC、學生讀取正確答案、結束後投票皆被拒絕。
- 允許修改答案時最終只有一筆投票，作答內容更新正常。
- 重設入班碼會使舊綁定失效，持有新入班碼後可重新綁定；教師能查閱出席紀錄。
- 1 秒限時題的交易延時測試：逾時後投票被拒絕，無票數寫入。修正：`supabase/05_fix_vote_deadline.sql`。
- PostgreSQL 功能測試全部以 `BEGIN ... ROLLBACK` 執行，確認沒有留下任何 E2E 教室、學生或票數。
- GitHub Actions `ClassPoll quality checks` 執行 JavaScript syntax、靜態 HTML 引用與設定檔 / RLS 規則檢查。以 GitHub Actions 顯示的最新結果為準。
- 已為 4 個缺少索引的外鍵補上索引；效能顧問已不再回報「Unindexed foreign keys」。

### 仍未達到全通過，不能當成完整真實 E2E
- 尚未在 **真實的兩個不同 Supabase Auth session 與瀏覽器** 進行教師登入、匿名學生登入、QR Code、斷線重連、Reatime 同步、Excel 匯出的連續驗收。SQL 交易模擬角色不等於真實 JWT/網路端到端測試。
- Supabase Auth Security Advisor 仍回報 `auth_leaked_password_protection` 未啟用；需在 Supabase Auth 設定中檢查並啟用（若目前方案支援）。
- 正式上線前應將示範教師帳號換成專用教師信箱、強密碼，確認 `Authentication → Providers → Anonymous Sign-ins` 啟用，並確認 RLS 隔離測試有不同帳號及裝置。


## 已在交付容器執行的檢查

- [x] `node --check` JavaScript 語法檢查（所有 JS）。
- [x] HTML DOM ID 參照、重複 ID 檢查。
- [x] 靜態頁面可以從本地 HTTP Server 提供；前台頁面可在 Chromium 開啟。
- [x] SQL 靜態檢查（表、函式、權限與 RLS 章節核對）。
- [ ] 真實 Supabase SQL Editor 執行與 Postgres 實際編譯 —— **需要專案所有者資料庫權限**。
- [ ] Supabase Auth Email + Anonymous 登入 —— **需要專案所有者開啟 Auth 設定與有效測試帳號**。
- [ ] 兩台裝置同時投票／斷線恢復／RLS 權限隔離 —— **需要連線後做實測**。
- [ ] GitHub Pages 公開網址部署 —— **需要你對儲存庫的寫入/Pages 設定權限**。

## 必須完成的正式驗收

1. 未授權教師 Email 登入後不得看到 Dashboard 或執行任何教室 RPC。
2. 教師 A 不得查詢/修改教師 B 的教室、學生、投票、答案。
3. 未持個人入班碼的匿名學生不得進入任一教室；錯碼不得洩露名冊。
4. 一個學生身分只會有一份每題投票資料。不可修改答案時，重複提交必須失敗。
5. 重複送出（兩個同時並行請求）只容許第一份寫入；允許修改時只能留下最後一份結果。
6. 試圖讀取 `cp2_answer_keys` 的學生必須被 RLS 擋住，即使有教室代碼也不可看到正確答案。
7. 測試截止時間後無法寫入，哪怕手動呼叫 RPC。
8. 斷網 30 秒後恢復，30 秒內應透過 Realtime 或週期讀取恢復最新題目/票數。
9. 教師重設入班碼後，舊登入裝置不能投票；新裝置可利用新碼綁定，歷史分數仍在。
10. 出席、成績、作答明細 XLSX/CSV 使用 Excel 開啟，學號不丟失前導零。

## 限制與威脅模型

- 個人入班碼是由教師配發的入班憑證，不代表已透過學校系統認證學生本人。若學生在第一次綁定前分享入班碼，第三者可能冒用。高風險正式成績應使用校方 SSO。
- 採用匿名 Supabase Auth，學生清除儲存空間後無法恢復原身分，需由教師重新簽發入班碼。
- RLS 能降低資料未授權存取風險，但需在正式資料庫執行測試；安裝腳本不是安全審計報告。
- 部署會載入第三方 CDN（Supabase JS、Chart.js、SheetJS、QRCode、Google Fonts）；CDN 故障時可能影響即時互動、繪圖或 XLSX。XLSX 失效時已設 CSV 備援。
- 時區：出席日以 Asia/Taipei 計算；即時截止時間由資料庫伺服器核對。
- Excel/CSV 含個資與個人入班碼，匯出後自行妥善保管，不要上傳到公開倉庫。
- 新版不含舊資料的自動移轉功能。


## 2026-10-15 第二輪程式修復與回歸測試

### 已修正並提交至 GitHub
- 教師端出席日期依 Asia/Taipei 的日期計算，避免不同行動裝置時區或系統語系造成跨日錯誤。
- 教師批次匯入遇到資料庫或同步錯誤時會恢復按鈕，不會把「失敗學生的姓名」清掉；已新增的學生入班碼仍留在畫面可匯出。
- 教師儀表板／測驗中的作答率僅計入仍啟用的學生，不會因停用曾投票的學生出現超過 100%。
- 教師在「學習分析」分頁時，票數定期補同步也會刷新成績及各題統計。
- 學生端的即時更新在 HTTP 請求重疊時會排隊補同步；切換教室後，舊教室回應不會覆蓋新教室畫面。
- 已確認投票成功的 RPC 不因回讀暫時斷線而誤顯示「投票失敗」。
- 學生在按下入班前不會無條件新增匿名 Auth 帳號；既有匿名工作階段仍會嘗試恢復。
- 教師登出時清空密碼輸入、尚未匯出的入班碼及記憶體中的教室／成績狀態。
- 學號不存在、停用或個人入班碼錯誤都會回傳同一段驗證失敗訊息，不提供名冊探測線索。已在正式資料庫使用交易回滾確認正常入班不受影響；修補檔：`supabase/06_join_error_privacy.sql`。

### 自動驗證
- GitHub Actions 的 `ClassPoll quality checks` 會額外執行 `node scripts/test-logic.mjs`，測試台灣日期跨年／跨日、停用學生比例及 HTML 跳脫。
- `ClassPoll deployed-pages smoke test` 檢查公開首頁、教師端、學生端及主要 JavaScript 回傳有效內容。
- 以上均不等於教師真實密碼登入與學生匿名 Auth JWT 的雙瀏覽器 E2E 測試；正式上線仍需要人工進行實際投票、重新整理、斷線恢復及 XLSX 檔案檢查。

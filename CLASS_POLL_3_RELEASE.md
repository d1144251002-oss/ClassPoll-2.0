# ClassPoll 3.0 龍華科技大學校園平台 — 重構與正式上線門檻

**狀態：未達發行門檻，請勿合併至 main、請勿修改正式資料庫。** 此文件屬於 PR #4 的開發／驗收計畫。現行 ClassPoll 2.0 不停機、原名冊和成績保留。

## 發行原則

1. 前端採用 Vue 3 + TypeScript + Vue Router，逐模組把現有 `iframe` 替換為真正的路由與 Vue 元件。未遷移模組仍使用 ClassPoll 2.0 正式版，不可把 placeholder 當完成功能。
2. DB 以向後相容 migration 漸進擴充；禁止因為「刪除學生或課程」而連帶刪除 `cp2_votes`、`cp2_attendance`、`cp2_ballot_*`。
3. 所有角色判斷需在 RLS／後端 RPC 中重做；Vue Router Guard 只能用來改善導覽，不能成為資安邊界。
4. 所有新權限、課程管理、成績與通知功能必須通過正向及越權的 PostgreSQL CI 測試。
5. 真實 Supabase／校方 SSO 整合、正式資料庫備份和恢復演練前，不准合併完整替換版。

## 十項功能與驗收矩陣

| 功能 | 本 PR 已有的可用成果 | 發布前仍須完成 |
|---|---|---|
| 1. Vue 3 / TypeScript SPA | `spa/` 可編譯的單一前端、教師路由、共用 session、總覽、課程安全管理 | 學生端、題庫、測驗、問答、報表、投票模組全部改寫；移除正式 iframe |
| 2. 校園 SSO + RBAC | 沿用 Supabase 教師白名單與現有 owner／assistant／auditor 保護，新增課程 staff 資料模型 | **需校方提供授權的 IdP、測試帳號、OIDC/SAML 設定、角色對應規範**；完成 admin／教務／助教／學生／稽核不同校區與系所的伺服器端 scope 授權 |
| 3. 角色化儀表板 | 真實 DB 教師教室數、學生人數、出席、近期錯誤 | 學生／教務／平台管理員專屬資訊與 server-side 統計 |
| 4. 學期／課程／班級 | `11_academic_core.sql` 具學年度、學期、系所、課程、協作角色，教室封存及學生停用與復原 | 科目建立、課程複製、選課、多教師授課授權與學期封存流程 |
| 5. 教學與成績 | 作業、成績權重表與可用的教師權重設定畫面、受控 RPC（尚不計算正式成績） | 作業提交、題庫版本、測驗排程、自動計分、人工覆核、正式成績簽核與不可竄改稽核 |
| 6. 備份／PITR | 現有 ClassPoll 2.0 AES-GCM 教室快照保留 | **由校方/DBA 確認 Supabase 專案備份能力、PITR、跨環境還原演練、留存與加密金鑰制度** |
| 7. 系統監控 | 現有錯誤紀錄、教師總覽顯示近 24 小時錯誤 | API 延遲與 SLA、Auth 成功率、Realtime 斷線、DB 指標、告警通報及資料最小化 |
| 8. 行動優先與 PWA | `spa/public/manifest.webmanifest`、service worker 只快取同源靜態 shell/assets | 真實 iOS/Android 安裝、背景模式、弱網路、鍵盤／螢幕閱讀器與 WCAG 稽核 |
| 9. 校園通知 | 公告與已讀資料結構、教師公告發布、學生已讀 RPC 及教師公告管理畫面 | 發布審核、學生自選訂閱、到期提醒、可稽核寄信／推播 provider、退訂流程 |
| 10. 資安 | 基礎 RLS／RPC、私有資料不可直接查表、CI SQL 反向測試、靜態 SW 快取限制 | 教師 MFA、外洩密碼防護、CSP、套件 SCA、WAF/限流、密鑰政策、弱點與滲透測試 |

## 本次已執行的安全設計

- `cp3_manage_student(student_id, 'disable' | 'restore', reason)`：僅原教室擁有者執行；停用與恢復只改狀態並寫 audit，不刪歷史分數。
- `cp3_archive_course(room_id, archived)`：僅原教室擁有者；封存課程並停用教室，恢復可開放。原本教室 FK、學生、考題與作答資料完整保留。
- `cp3_course_list()`：只回傳使用者擁有的教室。協作教師跨課寫入權限**尚未實作**，不得宣稱已能共同授課。
- `cp3_*` 表預設 RLS 開啟、`anon/authenticated` 不直接授權，僅透過驗證後 RPC 操作。
- 身分層只使用公開 Supabase URL／publishable key；絕不把 service_role／DB 密碼放進瀏覽器或 GitHub。
- PWA 不快取動態學生／Auth／成績／投票 API，且所有伺服器變更操作都需要網路和 RPC 正式確認。

## 正式上線作業條件

- [ ] 校方提供獲准使用的 SSO IdP／測試帳號／組織角色 mapping；若不使用校方 SSO，校方必須正式核准改用現行登入方案。
- [ ] 用獨立測試專案或完整回滾交易驗證新 SQL，確認 schema 和既有歷史資料均不遺失。
- [ ] 具有效教師、助教、學生、教務及稽核帳號的跨角色真實 E2E。
- [ ] 對原有所有模組做功能等價測試：建立／停用／恢復、作答、題庫、問答、報表、加密備份與表決。
- [ ] Playwright 桌面與手機瀏覽器測試、Vue 型別檢查、PostgreSQL RLS 越權測試全部成功。
- [ ] 校方已核准「永久刪除」政策。**預設僅停用／封存**，永久刪除由 DBA 在授權保留政策下獨立審核，不能在 UI 按鈕直接連鎖刪分數。
- [ ] 教師 MFA、Auth leaked-password protection、CSP、SCA、事件監控與警報演練完成。
- [ ] 資料庫全量備份與演練過的還原程序；PITR 依實際 Supabase 訂閱方案及校內資源決定，不可虛構啟用狀態。
- [ ] 完成校方資訊安全、個資與教育資料治理核准，且 GitHub Pages 或校內 HTTPS 服務完成發佈後 smoke test。

## 開發與驗證

```bash
cd spa
cp .env.example .env.local  # 僅填入公開 Project URL 和 publishable key
npm install
npm run build
npm run dev
```

- **隔離 SPA** 的路徑在 `spa/`，未替換現行根目錄的 `index.html`。
- `supabase/11_academic_core.sql` 為**候選遷移**，目前禁止在正式資料庫執行 `COMMIT`；正式上線前應由授權 DBA 備份並正式核准。
- `tests/db-cp3-integration.sql` 驗證 CRUD 生命周期、跨教師拒絕和歷史資料保護。

本文件不承諾零 BUG。CI 成功只能證明已涵蓋的案例通過，須由全功能真實驗收和校方權責核准決定上線。

## 階段一追加交付（2026-10-15）

- 增加 `supabase/12_academic_workflows.sql`，公告發布／已讀與權重設定所有操作只透過後端 RPC；`tests/db-cp3-workflows.sql` 測試學生冒充教師、跨課程資料讀取和評分比例不合法的攔截。
- Vue 教師端新增「公告中心」與「成績權重設定」，目前**不是作業繳交、正式成績輸出或校方寄信服務**。
- 教室與學生的 Vue 畫面支援新增教室、新增學生並顯示一次性的入班碼、封存與恢復。更完整的 CSV、人員權限與學籍整合仍在後續階段。
- PWA 具備 Manifest、靜態快取與離線入口機制；並未認證為完整離線課堂，不得離線提交成績或表決。

import {test,expect} from '@playwright/test';
import {readFileSync} from 'node:fs';

// These verify browser interactions with a mock SDK; real Auth E2E needs staging.
const sdk=readFileSync(new URL('./mock-supabase.js',import.meta.url),'utf8');
async function mockSupabase(page){
 await page.route('https://cdn.jsdelivr.net/**',route=>
  route.fulfill({status:200,contentType:'application/javascript',
   body:route.request().url().includes('supabase-js')?sdk:''}));
}
test('home exposes platform administration and existing teaching modules',async({page})=>{
 await page.goto('/index.html');
 await expect(page.locator('a[href="admin.html"]')).toBeVisible();
 await expect(page.locator('a[href="teacher.html"]')).toBeVisible();
 await expect(page.locator('a[href="ballots.html"]')).toBeVisible();
});
test('role-aware platform dashboard loads and filters classrooms',async({page})=>{
 await mockSupabase(page);await page.goto('/admin.html');
 await expect(page.locator('#roomTotal')).toHaveText('2');
 await expect(page.locator('#studentTotal')).toHaveText('5');
 await expect(page.locator('#presentTotal')).toHaveText('3');
 await expect(page.locator('#errorTotal')).toHaveText('1');
 await expect(page.locator('#roomRows tr')).toHaveCount(2);
 await page.locator('#roomSearch').fill('TEST02');
 await expect(page.locator('#roomRows tr')).toHaveCount(1);
 await expect(page.locator('#roomRows')).toContainText('稽核員');
 await expect(page.locator('#roleRoom option')).toHaveCount(1);
 await expect(page.locator('#backupRoom option')).toHaveCount(1);
});
test('teacher can access classroom Q&A and read pending messages',async({page})=>{
 await mockSupabase(page);await page.goto('/teacher.html');
 await expect(page.locator('#teacherApp')).toBeVisible();
 await page.locator('button[data-tab="qna"]').click();
 await expect(page.locator('#qnaTotal')).toHaveText('1');
 await expect(page.locator('#qnaPending')).toHaveText('1');
 await expect(page.locator('#qnaList')).toContainText('資料結構是什麼？');
});
test('student can join and ask a private classroom question',async({page})=>{
 await mockSupabase(page);await page.goto('/student.html');
 await page.locator('#joinRoom').fill('QA2026');
 await page.locator('#joinNumber').fill('QA123');
 await page.locator('#joinAccess').fill('1234567890abcdef1234567890abcdef');
 await page.locator('#joinBtn').click();
 await expect(page.locator('#studentPage')).toBeVisible();
 await page.locator('#qnaText').fill('請老師解釋鏈結串列的時間複雜度');
 await page.locator('#qnaSendBtn').click();
 await expect(page.locator('#toasts')).toContainText('問題已送給教師');
 await expect(page.locator('#qnaText')).toHaveValue('');
});

test('teacher can calculate and export a graded CSV report',async({page})=>{
 await mockSupabase(page);await page.goto('/teacher.html');
 await expect(page.locator('#teacherApp')).toBeVisible();
 await page.locator('button[data-tab="reports"]').click();
 await expect(page.locator('#scoreRows')).toContainText('王同學');
 await expect(page.locator('#scoreRows')).toContainText('5');
 const nextDownload=page.waitForEvent('download');
 await page.locator('#exportScores').click();
 const download=await nextDownload;
 expect(download.suggestedFilename()).toMatch(/\.csv$/);
});
test('mobile platform dashboard stays within the viewport',async({page})=>{
 await page.setViewportSize({width:390,height:844});
 await mockSupabase(page);await page.goto('/admin.html');
 await expect(page.locator('#roomTotal')).toHaveText('2');
 const width=await page.evaluate(()=>document.documentElement.scrollWidth);
 expect(width).toBeLessThanOrEqual(392);
});

test('admin logout removes sensitive classroom dashboard data from document',async({page})=>{
 await mockSupabase(page);await page.goto('/admin.html');
 await expect(page.locator('#roomRows')).toContainText('資料結構測試班');
 await page.locator('#logoutButton').click();
 await expect(page.locator('#loginGate')).toBeVisible();
 await expect(page.locator('#roomRows')).not.toContainText('資料結構測試班');
 await expect(page.locator('#roomTotal')).toHaveText('0');
 await expect(page.locator('#roleRoom option')).toHaveCount(0);
});
test('teacher logout clears student private history and any transient session UI',async({page})=>{
 await mockSupabase(page);await page.goto('/teacher.html');
 await page.locator('button[data-tab="qna"]').click();
 await expect(page.locator('#qnaList')).toContainText('資料結構是什麼？');
 await page.locator('#signoutBtn').click();
 await expect(page.locator('#authGate')).toBeVisible();
 await expect(page.locator('#qnaList')).not.toContainText('資料結構是什麼？');
 await expect(page.locator('#studentRows')).not.toContainText('王同學');
});

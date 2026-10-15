import {test,expect} from '@playwright/test';

test('university login and SPA shell render without iframe',async({page})=>{
 await page.goto('/');
 await expect(page.getByRole('heading',{name:'登入校園系統'})).toBeVisible();
 await expect(page.getByText('龍華科技大學').first()).toBeVisible();
 await expect(page.locator('iframe')).toHaveCount(0);
 await page.getByRole('button',{name:'學生'}).click();
 await expect(page.getByLabel('學號')).toBeVisible();
 await expect(page.getByLabel('個人入班碼')).toBeVisible();
 await page.getByRole('button',{name:'教師／行政人員'}).click();
 await expect(page.getByLabel('電子郵件')).toBeVisible();
});
test('protected URL without session never reveals school records',async({page})=>{
 await page.goto('/#/grades');
 await expect(page.getByRole('heading',{name:'登入校園系統'})).toBeVisible();
 await expect(page.getByText('學生學習成績')).toHaveCount(0);
 await expect(page.locator('iframe')).toHaveCount(0);
});
test('small-screen login is usable without horizontal overflow',async({page})=>{
 await page.setViewportSize({width:390,height:844});
 await page.goto('/');
 await expect(page.getByRole('heading',{name:'登入校園系統'})).toBeVisible();
 const width=await page.evaluate(()=>document.documentElement.scrollWidth);
 expect(width).toBeLessThanOrEqual(392);
});

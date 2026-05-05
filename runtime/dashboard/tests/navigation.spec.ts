import { test, expect } from '@playwright/test';

test.describe('Dashboard Navigation', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:3000');
  });

  test('should navigate to Connectivity page', async ({ page }) => {
    await page.getByRole('link', { name: /Connect/i }).click();
    await expect(page).toHaveURL('http://localhost:3000/connectivity');
    await expect(page.locator('h1')).toHaveText('Connectivity Management');
  });

  test('should navigate to NPU Lab page', async ({ page }) => {
    await page.getByRole('link', { name: /NPU Lab/i }).click();
    await expect(page).toHaveURL('http://localhost:3000/npu');
  });

  test('should navigate to Logs page', async ({ page }) => {
    await page.getByRole('link', { name: /Logs/i }).click();
    await expect(page).toHaveURL('http://localhost:3000/logs');
  });
});

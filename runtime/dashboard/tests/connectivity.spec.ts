import { test, expect } from '@playwright/test';

/**
 * Connectivity Status E2E Tests
 * 
 * Issue #16: Current Status Panel - tests that the connectivity page loads
 * and displays the current connection status.
 * 
 * Uses Playwright's route interception to mock API responses for reliable testing.
 */

// Mock data for testing
const mockStatus = {
  connected: true,
  ssid: 'Arlowe_WiFi_5G',
  ip_address: '192.168.1.101',
  signalStrength: '85%',
  networkType: 'Wi-Fi',
  security: 'WPA2',
};

const mockAvailableNetworks = [
  { ssid: 'Home_WiFi', security: 'WPA2', signal: 90, inUse: false },
  { ssid: 'Guest_Network', security: 'Open', signal: 75, inUse: false },
  { ssid: 'Office_Network_Secure', security: 'WPA3', signal: 60, inUse: false },
];

// Helper function to set up API mocks
async function setupMocks(page: import('@playwright/test').Page) {
  await page.route('**/api/connectivity/status', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(mockStatus),
    });
  });
  
  await page.route('**/api/connectivity/networks', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(mockAvailableNetworks),
    });
  });
  
  // Also mock the scan endpoint which NetworkList uses
  await page.route('**/api/connectivity/scan', async (route) => {
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(mockAvailableNetworks),
    });
  });
}

test.describe('Issue #16: Connectivity Status - Current Status Panel', () => {
  test.beforeEach(async ({ page }) => {
    await setupMocks(page);
    await page.goto('/connectivity');
  });

  test('page should load with WiFi Connectivity heading', async ({ page }) => {
    // The page has a header with WiFi Connectivity title
    const heading = page.locator('h1').filter({ hasText: 'WiFi Connectivity' });
    await expect(heading).toBeVisible();
  });

  test('should display Current Status panel with heading', async ({ page }) => {
    const statusPanel = page.locator('h2:has-text("Current Status")');
    await expect(statusPanel).toBeVisible();
  });

  test('should display connection status as Connected', async ({ page }) => {
    await expect(page.locator('text=Connected').first()).toBeVisible();
  });

  test('should display SSID from mocked data', async ({ page }) => {
    await expect(page.locator('text=Arlowe_WiFi_5G')).toBeVisible();
  });

  test('should display IP Address from mocked data', async ({ page }) => {
    await expect(page.locator('text=192.168.1.101')).toBeVisible();
  });

  test('Current Status panel should have proper styling', async ({ page }) => {
    const panel = page.locator('.bg-gray-800').filter({ hasText: 'Current Status' }).first();
    await expect(panel).toBeVisible();
    await expect(panel).toHaveClass(/rounded-lg/);
  });

  test('should display WiFi icon in status panel', async ({ page }) => {
    // Check for SVG icon (WiFi indicator) in the status panel
    const statusPanel = page.locator('.bg-gray-800').filter({ hasText: 'Current Status' });
    const svgIcon = statusPanel.locator('svg');
    await expect(svgIcon).toBeVisible();
  });

  test('screenshot: Current Status Panel complete view', async ({ page }) => {
    const panel = page.locator('.bg-gray-800').filter({ hasText: 'Current Status' }).first();
    await expect(panel).toBeVisible();
    // Screenshot will be captured automatically due to config
  });
});

test.describe('Issue #16: Connectivity Status - Page Integration', () => {
  test.beforeEach(async ({ page }) => {
    await setupMocks(page);
  });

  test('should display Current Status panel on the page', async ({ page }) => {
    await page.goto('/connectivity');
    await expect(page.locator('h2:has-text("Current Status")')).toBeVisible();
  });

  test('should display Available Networks panel on the page', async ({ page }) => {
    await page.goto('/connectivity');
    await expect(page.locator('h2:has-text("Available Networks")')).toBeVisible();
  });

  test('navigation should show Connectivity link', async ({ page }) => {
    await page.goto('/connectivity');
    
    // The connectivity nav item should exist
    const navItem = page.locator('nav a[href="/connectivity"]');
    await expect(navItem).toBeVisible();
  });

  test('page should have header with description', async ({ page }) => {
    await page.goto('/connectivity');
    
    // Check for the page description text
    const description = page.locator('text=Manage and connect to wireless networks');
    await expect(description).toBeVisible();
  });

  test('screenshot: Full Connectivity page overview', async ({ page }) => {
    await page.goto('/connectivity');
    
    // Both panels should be visible for screenshot
    await expect(page.locator('h2:has-text("Current Status")')).toBeVisible();
    await expect(page.locator('h2:has-text("Available Networks")')).toBeVisible();
    // Screenshot will be captured automatically
  });
});

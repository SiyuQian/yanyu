import { test, expect } from "@playwright/test";

test.describe("Yanyu App", () => {
  test("identifies the fork in the window title", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle("言语 · Yanyu");
  });

  test("dev server responds", async ({ page }) => {
    // Just verify the dev server is running and responds
    const response = await page.goto("/");
    expect(response?.status()).toBe(200);
  });

  test("page has html structure", async ({ page }) => {
    await page.goto("/");

    // Verify basic HTML structure exists
    const html = await page.content();
    expect(html).toContain("<html");
    expect(html).toContain("<body");
  });
});

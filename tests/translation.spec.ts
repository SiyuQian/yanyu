import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const callbacks = new Map<number, (event: unknown) => void>();
    let next = 0;
    let listener = 0;
    let themeListener = 0;
    let state = { phase: "loading", text: null, error: null, revision: 1 };
    Object.assign(window, {
      setTranslation: (nextState: typeof state) => {
        state = nextState;
        callbacks.get(listener)?.({ payload: state });
      },
      setTheme: (theme: string) => {
        callbacks.get(themeListener)?.({ payload: theme });
      },
      __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
      __TAURI_INTERNALS__: {
        transformCallback: (callback: (event: unknown) => void) => {
          callbacks.set(++next, callback);
          return next;
        },
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "plugin:event|listen") {
            if (args.event === "translation-state")
              listener = Number(args.handler);
            if (args.event === "theme-changed")
              themeListener = Number(args.handler);
            return Number(args.handler);
          }
          if (command === "get_translation_state") return state;
          if (command === "get_app_settings")
            return { app_language: "en", theme: "dark" };
          if (command === "copy_translation") {
            if (
              args.revision !== state.revision ||
              localStorage.getItem("copyFailure")
            )
              throw new Error("copy_failed");
            localStorage.setItem("clipboard", state.text || "");
            return null;
          }
          if (command === "dismiss_translation") {
            state = {
              ...state,
              phase: "idle",
              text: null,
              error: null,
              revision: state.revision + 1,
            };
            callbacks.get(listener)?.({ payload: state });
          }
          return null;
        },
      },
    });
    localStorage.setItem("clipboard", "sentinel");
  });
  await page.goto("/src/translation/index.html");
});

test("loading and result display preserve clipboard until Copy", async ({
  page,
}) => {
  await expect(page.getByRole("status")).toHaveText("Translating locally…");
  await expect(
    page.getByRole("button", { name: "Copy translation" }),
  ).toBeDisabled();
  await page.evaluate(() => {
    (
      window as unknown as { setTranslation: (state: unknown) => void }
    ).setTranslation({
      phase: "result",
      text: "你好，世界。",
      error: null,
      revision: 2,
    });
  });
  await expect(page.getByText("你好，世界。")).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "sentinel",
  );
  await page
    .getByRole("button", { name: "Copy translation", exact: true })
    .click();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "你好，世界。",
  );
});

test("selection polishing previews the result and copies only on request", async ({
  page,
}) => {
  await page.evaluate(() => {
    (
      window as unknown as { setTranslation: (state: unknown) => void }
    ).setTranslation({
      operation: "polish",
      phase: "loading",
      text: null,
      error: null,
      revision: 2,
    });
  });
  await expect(
    page.getByRole("heading", { name: "Polish selection" }),
  ).toBeVisible();
  await expect(page.getByRole("status")).toHaveText("Polishing locally…");
  await expect(
    page.getByRole("button", { name: "Copy polished text" }),
  ).toBeDisabled();
  await page.evaluate(() => {
    (
      window as unknown as { setTranslation: (state: unknown) => void }
    ).setTranslation({
      operation: "polish",
      phase: "result",
      text: "Could you please send me the file when you have a moment?",
      error: null,
      revision: 3,
    });
  });
  await expect(
    page.getByText("Could you please send me the file when you have a moment?"),
  ).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "sentinel",
  );
  await page
    .getByRole("button", { name: "Copy polished text", exact: true })
    .click();
  await expect(page.getByRole("button", { name: "Copied" })).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "Could you please send me the file when you have a moment?",
  );
});

test("dismissing selection polishing leaves the clipboard untouched", async ({
  page,
}) => {
  await page.evaluate(() => {
    (
      window as unknown as { setTranslation: (state: unknown) => void }
    ).setTranslation({
      operation: "polish",
      phase: "result",
      text: "謝謝你的幫忙！",
      error: null,
      revision: 2,
    });
  });
  await expect(page.getByText("謝謝你的幫忙！")).toBeVisible();
  await expect(page.getByText("謝謝你的幫忙！")).not.toHaveAttribute(
    "lang",
    "zh-CN",
  );
  await page.keyboard.press("Escape");
  await expect(
    page.getByRole("button", { name: "Copy polished text" }),
  ).toBeDisabled();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "sentinel",
  );
});

test("polishing errors explain model setup without changing the clipboard", async ({
  page,
}) => {
  await page.evaluate(() => {
    (
      window as unknown as { setTranslation: (state: unknown) => void }
    ).setTranslation({
      operation: "polish",
      phase: "error",
      text: null,
      error: "missing_model",
      revision: 2,
    });
  });
  await expect(page.getByRole("alert")).toContainText(
    "Download Qwen3-0.6B in General settings to polish locally.",
  );
  await expect(
    page.getByRole("button", { name: "Open model settings" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Copy polished text" }),
  ).toBeDisabled();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "sentinel",
  );
});

test("failed polishing copy remains visible and leaves the clipboard untouched", async ({
  page,
}) => {
  await page.evaluate(() => {
    localStorage.setItem("copyFailure", "true");
    (
      window as unknown as { setTranslation: (state: unknown) => void }
    ).setTranslation({
      operation: "polish",
      phase: "result",
      text: "Thanks for your help!",
      error: null,
      revision: 2,
    });
  });
  await page.getByRole("button", { name: "Copy polished text" }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "Could not copy the polished text. Try again.",
  );
  await expect(page.getByText("Thanks for your help!")).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "sentinel",
  );
});

for (const error of [
  "permission_denied",
  "no_selection",
  "unsupported_selection",
  "missing_model",
]) {
  test(`${error} is localized and dismissal preserves clipboard`, async ({
    page,
  }) => {
    await expect(page.getByRole("status")).toBeVisible();
    await page.evaluate((error) => {
      (
        window as unknown as { setTranslation: (state: unknown) => void }
      ).setTranslation({
        phase: "error",
        text: null,
        error,
        revision: 2,
      });
    }, error);
    await expect(page.getByRole("alert")).not.toBeEmpty();
    await expect(
      page.getByRole("button", { name: "Copy translation" }),
    ).toBeDisabled();
    if (error === "missing_model") {
      await expect(
        page.getByRole("button", { name: "Open model settings" }),
      ).toBeVisible();
    }
    await page.getByRole("button", { name: "Close" }).click();
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      "sentinel",
    );
  });
}

test("translation reconciles persisted theme and follows live changes", async ({
  page,
}) => {
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.evaluate(() => {
    (window as unknown as { setTheme: (theme: string) => void }).setTheme(
      "light",
    );
  });
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await page.evaluate(() => {
    (window as unknown as { setTheme: (theme: string) => void }).setTheme(
      "system",
    );
  });
  await expect(page.locator("html")).not.toHaveAttribute("data-theme");
});

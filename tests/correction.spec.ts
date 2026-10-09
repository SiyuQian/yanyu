import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    let draft = "Hello old name";
    let word: string | null = null;
    let fail = false;
    let generation = 1;
    Object.assign(window, {
      __TAURI_INTERNALS__: {
        transformCallback: () => 1,
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "get_app_settings")
            return { app_language: "en", theme: "light" };
          if (command === "get_correction_session")
            return { generation, draft, word };
          if (command === "save_correction_draft") {
            draft = args.draft as string;
            word = args.word as string | null;
            return null;
          }
          if (command === "test_new_dictation") {
            generation = 2;
            draft = "New delivered text";
            return null;
          }
          if (command === "apply_correction") {
            if (args.generation !== generation) throw "stale_session";
            if (fail) throw "copy_failed";
            draft = args.draft as string;
            return "copied";
          }
          if (command === "close_correction") return null;
          if (command === "test_fail") {
            fail = true;
            return null;
          }
          return null;
        },
      },
    });
  });
  await page.setViewportSize({ width: 560, height: 400 });
  await page.goto("/src/correction/index.html");
});

test("edits latest delivered text and clearly reports copy fallback", async ({
  page,
}) => {
  const editor = page.getByRole("textbox", { name: "Corrected text" });
  await expect(editor).toHaveValue("Hello old name");
  await editor.fill("Hello Yanyu");
  await editor.press("Enter");
  await expect(page.getByRole("status")).toContainText("Copied");
  await page.screenshot({
    path: "work/agent-runs/20261009T202649Z-personal-vocabulary/correction-ui.png",
  });
});

test("explicitly remembers selected corrected vocabulary without retyping", async ({
  page,
}) => {
  const editor = page.getByRole("textbox", { name: "Corrected text" });
  await editor.fill("Hello Yanyu");
  await editor.press("End");
  await editor.press("Shift+ArrowLeft");
  await editor.press("Shift+ArrowLeft");
  await editor.press("Shift+ArrowLeft");
  await editor.press("Shift+ArrowLeft");
  await editor.press("Shift+ArrowLeft");
  await page.getByRole("button", { name: "Remember selected word" }).click();
  await expect(page.getByText("Remember: Yanyu")).toBeVisible();
});

test("composition Enter does not submit and Shift Enter inserts a newline", async ({
  page,
}) => {
  const editor = page.getByRole("textbox", { name: "Corrected text" });
  await expect(editor).toHaveValue("Hello old name");
  await editor.dispatchEvent("compositionstart");
  await editor.press("Enter");
  await expect(page.getByRole("status")).not.toContainText("Copied");
  await editor.dispatchEvent("compositionend");
  await editor.press("Shift+Enter");
  await expect(editor).toHaveValue(/\n/);
});

test("reopening preserves the draft", async ({ page }) => {
  const editor = page.getByRole("textbox", { name: "Corrected text" });
  await editor.fill("My preserved draft");
  await editor.press("Escape");
  // A persistent webview stays mounted when the native window is hidden.
  await expect(editor).toHaveValue("My preserved draft");
});

test("output errors preserve edits and report failure", async ({ page }) => {
  const editor = page.getByRole("textbox", { name: "Corrected text" });
  await editor.fill("Keep this correction");
  await page.evaluate(() => {
    const runtime = (
      window as unknown as {
        __TAURI_INTERNALS__: {
          invoke: (command: string, args: object) => Promise<unknown>;
        };
      }
    ).__TAURI_INTERNALS__;
    return runtime.invoke("test_fail", {});
  });
  await editor.press("Enter");
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(editor).toHaveValue("Keep this correction");
});

test("stale drafts stay visible until explicitly replaced by latest dictation", async ({
  page,
}) => {
  const editor = page.getByRole("textbox", { name: "Corrected text" });
  await editor.fill("My old edits");
  await page.evaluate(() => {
    return (
      window as unknown as {
        __TAURI_INTERNALS__: {
          invoke: (command: string, args: object) => Promise<unknown>;
        };
      }
    ).__TAURI_INTERNALS__.invoke("test_new_dictation", {});
  });
  await editor.press("Enter");
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(editor).toHaveValue("My old edits");
  await page
    .getByRole("button", { name: "Load latest (discard draft)" })
    .click();
  await expect(editor).toHaveValue("New delivered text");
});

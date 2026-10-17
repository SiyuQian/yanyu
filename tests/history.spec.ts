import { test, expect, type Page } from "@playwright/test";
import type { HistoryEntry } from "@/bindings";

const entry: HistoryEntry = {
  id: 1,
  file_name: "synthetic.wav",
  timestamp: 100,
  saved: false,
  title: "Synthetic recording",
  transcription_text: "recognized source",
  post_processed_text: "  polished source  ",
  post_process_prompt: "prompt",
  post_process_requested: true,
  post_process_skip_reason: null,
  user_corrected_text: null,
};

async function mount(page: Page, overrides: Partial<HistoryEntry> = {}) {
  await page.addInitScript(
    (initial) => {
      let saved =
        JSON.parse(localStorage.getItem("history-fixture") || "null") ||
        initial;
      const callbacks = new Map<number, (event: unknown) => void>();
      let nextCallback = 1;
      Object.assign(window, {
        __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
        __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
        __TAURI_INTERNALS__: {
          transformCallback: (callback: (event: unknown) => void) => {
            callbacks.set(nextCallback, callback);
            return nextCallback++;
          },
          invoke: async (command: string, args: Record<string, unknown>) => {
            if (command === "plugin:event|listen") {
              (
                window as unknown as { emitHistory: (entry: unknown) => void }
              ).emitHistory = (updated) =>
                callbacks.get(args.handler as number)?.({
                  payload: { action: "updated", entry: updated },
                });
              return 1;
            }
            if (command === "get_history_entries")
              return { entries: [saved], has_more: false };
            if (command === "update_history_entry_correction") {
              localStorage.setItem("last-save", JSON.stringify(args));
              const failure = localStorage.getItem("save-failure");
              if (failure === "result") throw "write failed";
              if (failure === "invoke") throw new Error("invoke failed");
              if (localStorage.getItem("save-pending"))
                await new Promise<void>((resolve) => {
                  (window as unknown as { finishSave: () => void }).finishSave =
                    resolve;
                });
              saved = { ...saved, user_corrected_text: args.text };
              localStorage.setItem("history-fixture", JSON.stringify(saved));
              return saved;
            }
            if (command === "retry_history_entry_transcription") {
              await new Promise<void>((resolve) => {
                (window as unknown as { finishRetry: () => void }).finishRetry =
                  resolve;
              });
            }
            return null;
          },
        },
      });
      Object.defineProperty(navigator, "clipboard", {
        value: {
          writeText: async (text: string) =>
            localStorage.setItem("clipboard", text),
        },
      });
    },
    { ...entry, ...overrides },
  );
  await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `import React from '/node_modules/.vite/deps/react.js';
      import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
      import { HistorySettings } from '/src/components/settings/history/HistorySettings.tsx';
      import '/src/i18n/index.ts'; import '/src/App.css';
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(HistorySettings));`,
    }),
  );
  await page.goto("/");
}
const edit = (page: Page) =>
  page.getByRole("button", { name: "Edit transcript", exact: true });
const editor = (page: Page) =>
  page.getByRole("textbox", { name: "Corrected transcript" });
const copy = (page: Page) =>
  page.getByRole("button", {
    name: "Copy transcription to clipboard",
    exact: true,
  });
const save = (page: Page) =>
  page.getByRole("button", { name: "Save", exact: true });

for (const [polished, displayed] of [
  ["  polished source  ", "polished source"],
  ["", "recognized source"],
  [" \t\n", "recognized source"],
  [null, "recognized source"],
] as const) {
  test(`unedited history keeps fallback for ${JSON.stringify(polished)}`, async ({
    page,
  }) => {
    await mount(page, { post_processed_text: polished });
    await copy(page).click();
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      displayed,
    );
    await edit(page).focus();
    await page.keyboard.press("Enter");
    await expect(editor(page)).toHaveValue(displayed);
  });
}

test("saves exact corrections, preserves sources, and copies persisted text after reload", async ({
  page,
}) => {
  await mount(page);
  await edit(page).click();
  await editor(page).fill("  corrected term\n ");
  await copy(page).click();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "polished source",
  );
  await save(page).click();
  await expect(editor(page)).toHaveCount(0);
  expect(
    await page.evaluate(() => JSON.parse(localStorage.getItem("last-save")!)),
  ).toEqual({ id: 1, text: "  corrected term\n " });
  await expect(
    page.getByText("recognized source", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("polished source", { exact: true }),
  ).toBeVisible();
  await page.reload();
  await copy(page).click();
  expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
    "  corrected term\n ",
  );
  await edit(page).click();
  await expect(editor(page)).toHaveValue("  corrected term\n ");
});

for (const blank of ["", "   ", "\t\n"]) {
  test(`rejects blank draft ${JSON.stringify(blank)} and allows recovery`, async ({
    page,
  }) => {
    await mount(page);
    await edit(page).click();
    await editor(page).fill(blank);
    await save(page).click();
    await expect(page.getByRole("alert")).toHaveText(
      "Enter a transcript before saving.",
    );
    await expect(editor(page)).toHaveValue(blank);
    expect(
      await page.evaluate(() => localStorage.getItem("last-save")),
    ).toBeNull();
    await editor(page).fill(" valid ");
    await save(page).click();
    await expect(editor(page)).toHaveCount(0);
    await copy(page).click();
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      " valid ",
    );
  });
}

for (const failure of ["result", "invoke"]) {
  test(`retains draft and saved text after ${failure} failure and Cancel`, async ({
    page,
  }) => {
    await mount(page);
    await edit(page).click();
    await editor(page).fill("draft");
    await page.evaluate(
      (mode) => localStorage.setItem("save-failure", mode),
      failure,
    );
    await save(page).click();
    await expect(page.getByRole("alert")).toHaveText(
      "Failed to save transcript. Please try again.",
    );
    await expect(editor(page)).toHaveValue("draft");
    await copy(page).click();
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      "polished source",
    );
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await edit(page).click();
    await expect(editor(page)).toHaveValue("polished source");
  });
}

for (const failure of ["result", "invoke"]) {
  test(`failed re-edit preserves correction and retries draft after ${failure} failure`, async ({
    page,
  }) => {
    await mount(page, { user_corrected_text: "  saved correction\n " });
    await edit(page).click();
    await expect(editor(page)).toHaveValue("  saved correction\n ");
    await editor(page).fill("discarded draft");
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    expect(
      await page.evaluate(() => localStorage.getItem("last-save")),
    ).toBeNull();
    await edit(page).click();
    await expect(editor(page)).toHaveValue("  saved correction\n ");
    await editor(page).fill("  replacement correction\n ");
    await page.evaluate(
      (mode) => localStorage.setItem("save-failure", mode),
      failure,
    );
    await save(page).click();
    await expect(page.getByRole("alert")).toHaveText(
      "Failed to save transcript. Please try again.",
    );
    await expect(editor(page)).toHaveValue("  replacement correction\n ");
    await copy(page).click();
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      "  saved correction\n ",
    );
    await page.evaluate(() => localStorage.removeItem("save-failure"));
    await save(page).click();
    await expect(editor(page)).toHaveCount(0);
    await page.reload();
    await copy(page).click();
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      "  replacement correction\n ",
    );
    await edit(page).click();
    await expect(editor(page)).toHaveValue("  replacement correction\n ");
  });
}

test("disables conflicting row actions while saving", async ({ page }) => {
  await mount(page);
  await edit(page).click();
  await editor(page).fill("saved");
  await page.evaluate(() => localStorage.setItem("save-pending", "yes"));
  await save(page).click();
  for (const name of [
    "Save",
    "Cancel",
    "Delete entry",
    "Re-transcribe",
    "Save transcription",
    "Copy transcription to clipboard",
  ]) {
    await expect(
      page.getByRole("button", { name, exact: true }),
    ).toBeDisabled();
  }
  await page.evaluate(() =>
    (window as unknown as { finishSave: () => void }).finishSave(),
  );
  await expect(editor(page)).toHaveCount(0);
});

test("prevents saving a draft during re-transcription", async ({ page }) => {
  await mount(page);
  await edit(page).click();
  await editor(page).fill("draft");
  await page
    .getByRole("button", { name: "Re-transcribe", exact: true })
    .click();
  await expect(save(page)).toBeDisabled();
  expect(
    await page.evaluate(() => localStorage.getItem("last-save")),
  ).toBeNull();
});

for (const raw of ["", " \t\n"]) {
  test(`keeps no-text retry path for ${JSON.stringify(raw)}`, async ({
    page,
  }) => {
    await mount(page, {
      transcription_text: raw,
      post_processed_text: "inconsistent source",
    });
    await expect(
      page.getByText(
        "Transcription failed. You can re-transcribe using the retry icon.",
        { exact: true },
      ),
    ).toBeVisible();
    await expect(copy(page)).toBeDisabled();
    await expect(edit(page)).toHaveCount(0);
    await copy(page).evaluate((button: HTMLButtonElement) => button.click());
    expect(
      await page.evaluate(() => localStorage.getItem("clipboard")),
    ).toBeNull();
    await page
      .getByRole("button", { name: "Re-transcribe", exact: true })
      .click();
    await expect(copy(page)).toBeDisabled();
    await copy(page).evaluate((button: HTMLButtonElement) => button.click());
    expect(
      await page.evaluate(() => localStorage.getItem("clipboard")),
    ).toBeNull();
    await page.evaluate(
      (updated) => {
        const boundary = window as unknown as {
          finishRetry: () => void;
          emitHistory: (entry: unknown) => void;
        };
        boundary.emitHistory(updated);
        boundary.finishRetry();
      },
      { ...entry, transcription_text: "retried", post_processed_text: null },
    );
    await expect(edit(page)).toBeEnabled();
    await copy(page).focus();
    await page.keyboard.press("Enter");
    expect(await page.evaluate(() => localStorage.getItem("clipboard"))).toBe(
      "retried",
    );
  });
}

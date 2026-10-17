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

async function mount(
  page: Page,
  overrides: Partial<HistoryEntry> = {},
  customWords: string[] = [],
) {
  await page.addInitScript(
    (initial: { entry: HistoryEntry; customWords: string[] }) => {
      let saved =
        JSON.parse(localStorage.getItem("history-fixture") || "null") ||
        initial.entry;
      if (localStorage.getItem("custom-words") === null)
        localStorage.setItem(
          "custom-words",
          JSON.stringify(initial.customWords),
        );
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
            if (command === "update_custom_words") {
              if (localStorage.getItem("word-pending"))
                await new Promise<void>((resolve) => {
                  (
                    window as unknown as { finishWordUpdate: () => void }
                  ).finishWordUpdate = resolve;
                });
              const failure = localStorage.getItem("word-failure");
              if (failure === "result") throw "write failed";
              if (failure === "invoke") throw new Error("invoke failed");
              localStorage.setItem("custom-words", JSON.stringify(args.words));
              return null;
            }
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
    { entry: { ...entry, ...overrides }, customWords },
  );
  await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `import React from '/node_modules/.vite/deps/react.js';
      import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
      import { HistorySettings } from '/src/components/settings/history/HistorySettings.tsx';
      import { useSettingsStore } from '/src/stores/settingsStore.ts';
      import '/src/i18n/index.ts'; import '/src/App.css';
      useSettingsStore.setState({ settings: { custom_words: JSON.parse(localStorage.getItem('custom-words') || '[]') }, isLoading: false });
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(HistorySettings));`,
    }),
  );
  await page.goto("/");
}
const edit = (page: Page) =>
  page.getByRole("button", { name: "Edit transcript", exact: true });
const editor = (page: Page) =>
  page.getByRole("textbox", { name: "Corrected transcript", exact: true });
const copy = (page: Page) =>
  page.getByRole("button", {
    name: "Copy transcription to clipboard",
    exact: true,
  });
const save = (page: Page) =>
  page.getByRole("button", { name: "Save", exact: true });
const savedCorrection = (page: Page) =>
  page.getByRole("textbox", { name: "Saved corrected transcript" });

async function selectSavedCorrection(page: Page, start = 0, end?: number) {
  await savedCorrection(page).evaluate(
    (element, selection) => {
      const textarea = element as HTMLTextAreaElement;
      textarea.focus();
      textarea.setSelectionRange(
        selection.start,
        selection.end ?? textarea.value.length,
      );
      textarea.dispatchEvent(new Event("select", { bubbles: true }));
      textarea.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    },
    { start, end },
  );
}

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

test("adds a mouse-selected saved correction to the custom vocabulary", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "My corrected phrase" });
  await expect(savedCorrection(page)).toHaveValue("My corrected phrase");
  await savedCorrection(page).selectText();
  await savedCorrection(page).dispatchEvent("mouseup");
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Add to vocabulary" }).click();
  expect(
    await page.evaluate(() =>
      JSON.parse(localStorage.getItem("custom-words")!),
    ),
  ).toEqual(["My corrected phrase"]);
  await expect(page.getByRole("status")).toHaveText("Added to vocabulary.");
});

test("supports keyboard selection in the saved correction", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Keyboard term" });
  const correction = savedCorrection(page);
  await expect(correction).toHaveValue("Keyboard term");
  await correction.focus();
  expect(
    await correction.evaluate((element) => document.activeElement === element),
  ).toBe(true);
  await page.keyboard.press("ControlOrMeta+A");
  await expect
    .poll(() =>
      correction.evaluate(
        (element) => (element as HTMLTextAreaElement).selectionEnd,
      ),
    )
    .toBe("Keyboard term".length);
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toBeEnabled();
  await page.keyboard.press("Tab");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("status")).toHaveText("Added to vocabulary.");
});

test("rejects recognized text and bounds selection to the saved correction", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Saved words" });
  const add = page.getByRole("button", { name: "Add to vocabulary" });
  const source = page.getByText("recognized source", { exact: true });
  await source.evaluate((element) => {
    const range = document.createRange();
    range.selectNodeContents(element);
    window.getSelection()?.removeAllRanges();
    window.getSelection()?.addRange(range);
    element.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
  });
  await expect(add).toBeDisabled();
  await expect(savedCorrection(page)).toHaveValue("Saved words");
  await selectSavedCorrection(page);
  await expect(add).toBeEnabled();
  await add.click();
  expect(
    await page.evaluate(() =>
      JSON.parse(localStorage.getItem("custom-words")!),
    ),
  ).toEqual(["Saved words"]);
});

test("clears an empty saved selection and selections moved to unrelated text", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Saved words" });
  const correction = savedCorrection(page);
  const add = page.getByRole("button", { name: "Add to vocabulary" });
  await correction.focus();
  await page.keyboard.press("ControlOrMeta+A");
  await expect(add).toBeEnabled();
  await correction.evaluate((element) => {
    const textarea = element as HTMLTextAreaElement;
    textarea.setSelectionRange(0, 0);
    textarea.dispatchEvent(
      new KeyboardEvent("keyup", { key: "ArrowRight", bubbles: true }),
    );
  });
  await expect(add).toBeDisabled();

  await selectSavedCorrection(page);
  await expect(add).toBeEnabled();
  await page.getByText("recognized source", { exact: true }).click();
  await expect(add).toBeDisabled();
});

test("reports a normalized-empty selection without changing vocabulary", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "<>'\"" });
  await selectSavedCorrection(page);
  await expect(page.getByRole("alert")).toHaveText("Enter a valid word.");
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    "[]",
  );
});

test("reports a 51-unit selection without changing vocabulary", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "x".repeat(51) });
  await selectSavedCorrection(page);
  await expect(page.getByRole("alert")).toHaveText(
    "Words must be 50 characters or fewer.",
  );
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    "[]",
  );
});

test("accepts a 50-unit saved correction", async ({ page }) => {
  const word = "x".repeat(50);
  await mount(page, { user_corrected_text: word });
  await selectSavedCorrection(page);
  await page.getByRole("button", { name: "Add to vocabulary" }).click();
  expect(
    await page.evaluate(() =>
      JSON.parse(localStorage.getItem("custom-words")!),
    ),
  ).toEqual([word]);
});

test("reports a normalized duplicate from history", async ({ page }) => {
  await mount(page, { user_corrected_text: "<Saved>   word" }, ["Saved word"]);
  await selectSavedCorrection(page);
  await page.getByRole("button", { name: "Add to vocabulary" }).click();
  await expect(page.getByRole("alert")).toHaveText(
    '"Saved word" already exists',
  );
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    '["Saved word"]',
  );
});

test("clears a saved selection when editing or retrying starts", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Saved term" });
  await selectSavedCorrection(page);
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toBeEnabled();
  await edit(page).click();
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toBeDisabled();

  await selectSavedCorrection(page);
  await page
    .getByRole("button", { name: "Re-transcribe", exact: true })
    .click();
  await expect(
    page.getByText("Transcribing...", { exact: true }),
  ).toBeVisible();
  await page.evaluate(() =>
    (window as unknown as { finishRetry: () => void }).finishRetry(),
  );
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toBeDisabled();
});

test("disables history vocabulary updates while the shared word list is pending", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Pending term" });
  await page.evaluate(() => localStorage.setItem("word-pending", "yes"));
  await selectSavedCorrection(page);
  await page.getByRole("button", { name: "Add to vocabulary" }).click();
  await expect(
    page.getByRole("button", { name: "Add to vocabulary" }),
  ).toBeDisabled();
  await page.evaluate(() =>
    (window as unknown as { finishWordUpdate: () => void }).finishWordUpdate(),
  );
  await expect(page.getByRole("status")).toHaveText("Added to vocabulary.");
});

for (const failure of ["result", "invoke"]) {
  test(`preserves vocabulary and reports ${failure} failure for history addition`, async ({
    page,
  }) => {
    await mount(page, { user_corrected_text: "Saved word" }, ["existing"]);
    await page.evaluate(() => localStorage.setItem("word-pending", "yes"));
    await page.evaluate(
      (mode) => localStorage.setItem("word-failure", mode),
      failure,
    );
    await selectSavedCorrection(page);
    await page.keyboard.press("Tab");
    await page.keyboard.press("Enter");
    await expect(
      page.getByRole("button", { name: "Add to vocabulary" }),
    ).toBeDisabled();
    await page.evaluate(() =>
      (
        window as unknown as { finishWordUpdate: () => void }
      ).finishWordUpdate(),
    );
    await expect(page.getByRole("alert")).toHaveText(
      "Failed to update custom words. Please try again.",
    );
    expect(
      await page.evaluate(() => localStorage.getItem("custom-words")),
    ).toBe('["existing"]');
    const add = page.getByRole("button", { name: "Add to vocabulary" });
    await expect(add).toBeEnabled();
    await page.evaluate(() => {
      localStorage.removeItem("word-failure");
      localStorage.removeItem("word-pending");
    });
    await add.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByRole("status")).toHaveText("Added to vocabulary.");
    expect(
      await page.evaluate(() => localStorage.getItem("custom-words")),
    ).toBe('["existing","Saved word"]');
  });
}

test("keeps the full wrapped saved correction visible after retry remount", async ({
  page,
}) => {
  await mount(page, {
    user_corrected_text: "Wrapped saved correction ".repeat(60),
  });
  const correction = savedCorrection(page);
  await expect
    .poll(() =>
      correction.evaluate((node) => node.clientHeight - node.scrollHeight),
    )
    .toBeGreaterThanOrEqual(0);
  await page
    .getByRole("button", { name: "Re-transcribe", exact: true })
    .click();
  await expect(correction).toHaveCount(0);
  await page.evaluate(() =>
    (window as unknown as { finishRetry: () => void }).finishRetry(),
  );
  await expect(correction).toBeVisible();
  await expect
    .poll(() =>
      correction.evaluate((node) => node.clientHeight - node.scrollHeight),
    )
    .toBeGreaterThanOrEqual(0);
});

test("fits the saved correction after width changes without resize feedback errors", async ({
  page,
}) => {
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.setViewportSize({ width: 1200, height: 900 });
  await mount(page, {
    user_corrected_text: "Wrapped saved correction ".repeat(60),
  });
  const correction = savedCorrection(page);
  await expect(correction).toBeVisible();
  const initialHeight = await correction.evaluate((node) => node.clientHeight);
  await page.setViewportSize({ width: 480, height: 900 });
  await expect
    .poll(() => correction.evaluate((node) => node.clientHeight))
    .toBeGreaterThan(initialHeight);
  await expect
    .poll(() =>
      correction.evaluate((node) => node.clientHeight - node.scrollHeight),
    )
    .toBeGreaterThanOrEqual(0);
  await correction.evaluate((node) => {
    node.parentElement!.style.width = "240px";
  });
  await expect
    .poll(() =>
      correction.evaluate((node) => node.clientHeight - node.scrollHeight),
    )
    .toBeGreaterThanOrEqual(0);
  await page.evaluate(async () => {
    for (let i = 0; i < 4; i++) await new Promise(requestAnimationFrame);
  });
  expect(errors).toEqual([]);
});

test("clears saved selection after keyboard focus leaves the text and Add region", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Saved term" });
  const add = page.getByRole("button", { name: "Add to vocabulary" });
  await selectSavedCorrection(page);
  await page.keyboard.press("Tab");
  await expect(add).toBeFocused();
  await expect(add).toBeEnabled();
  await page.keyboard.press("Tab");
  await expect(add).toBeDisabled();
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    "[]",
  );
});

test("clears saved selection when leaving Add to select unrelated text", async ({
  page,
}) => {
  await mount(page, { user_corrected_text: "Saved term" });
  const add = page.getByRole("button", { name: "Add to vocabulary" });
  await selectSavedCorrection(page);
  await page.keyboard.press("Tab");
  await page.getByText("recognized source", { exact: true }).dblclick();
  await expect(add).toBeDisabled();
});

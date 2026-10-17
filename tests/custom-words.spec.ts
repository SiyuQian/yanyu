import { test, expect, type Page } from "@playwright/test";
import {
  normalizeCustomWord,
  getCustomWordValidationError,
} from "@/utils/customWord";

async function mount(page: Page, words: string[] = []) {
  await page.addInitScript((initialWords) => {
    if (localStorage.getItem("custom-words") === null)
      localStorage.setItem("custom-words", JSON.stringify(initialWords));
    Object.assign(window, {
      __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
      __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
      __TAURI_INTERNALS__: {
        transformCallback: () => 1,
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "change_audio_feedback_setting") {
            await new Promise<void>((_resolve, reject) => {
              (
                window as unknown as { failAudioUpdate: () => void }
              ).failAudioUpdate = () =>
                reject(new Error("audio update failed"));
            });
          }
          if (command === "update_custom_words") {
            const failure = localStorage.getItem("word-failure");
            if (failure === "result") throw "write failed";
            if (failure === "invoke") throw new Error("invoke failed");
            if (localStorage.getItem("word-pending"))
              await new Promise<void>((resolve) => {
                (
                  window as unknown as { finishWordUpdate: () => void }
                ).finishWordUpdate = resolve;
              });
            localStorage.setItem("custom-words", JSON.stringify(args.words));
            return null;
          }
          return null;
        },
      },
    });
  }, words);
  await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `import React from '/node_modules/.vite/deps/react.js';
      import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
      import { CustomWords } from '/src/components/settings/CustomWords.tsx';
      import { useSettingsStore } from '/src/stores/settingsStore.ts';
      import '/src/i18n/index.ts'; import '/src/App.css';
      useSettingsStore.setState({ settings: { audio_feedback: false, custom_words: JSON.parse(localStorage.getItem('custom-words') || '[]') }, isLoading: false });
      Object.assign(window, { beginAudioUpdate: () => useSettingsStore.getState().updateSetting('audio_feedback', true), readSettings: () => useSettingsStore.getState().settings, updateWordsTwice: () => Promise.allSettled([
        useSettingsStore.getState().updateCustomWords(['first']),
        useSettingsStore.getState().updateCustomWords(['second']),
      ]) });
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(CustomWords));`,
    }),
  );
  await page.goto("/");
}

const wordInput = (page: Page) => page.getByPlaceholder("Add a word");

test("adds a normalized word and keeps it after reload", async ({ page }) => {
  await mount(page);
  await wordInput(page).fill("  <Acme>   Widget  ");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Remove Acme Widget" }),
  ).toBeVisible();
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Remove Acme Widget" }),
  ).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    '["Acme Widget"]',
  );
});

test("reports sanitized-empty input and accepts 50 UTF-16 units", async ({
  page,
}) => {
  await mount(page);
  await wordInput(page).fill("<>\"'");
  await expect(page.getByRole("alert")).toHaveText("Enter a valid word.");
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    "[]",
  );

  const fiftyUnits = "x".repeat(50);
  await wordInput(page).fill(fiftyUnits);
  await expect(page.getByRole("alert")).toHaveCount(0);
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(
    page.getByRole("button", { name: `Remove ${fiftyUnits}` }),
  ).toBeVisible();
});

test("reports 51 UTF-16 units and a normalized duplicate", async ({ page }) => {
  await mount(page, ["Acme Widget"]);
  await wordInput(page).fill("x".repeat(51));
  await expect(page.getByRole("alert")).toHaveText(
    "Words must be 50 characters or fewer.",
  );
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(
    "Words must be 50 characters or fewer.",
  );
  await wordInput(page).fill("<Acme>   Widget");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText(
    '"Acme Widget" already exists',
  );
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    '["Acme Widget"]',
  );
});

for (const failure of ["result", "invoke"]) {
  test(`preserves dictionary and input after ${failure} failure`, async ({
    page,
  }) => {
    await mount(page, ["Existing"]);
    await page.evaluate(
      (mode) => localStorage.setItem("word-failure", mode),
      failure,
    );
    await wordInput(page).fill("New term");
    await page.getByRole("button", { name: "Add", exact: true }).click();
    await expect(page.getByRole("alert")).toHaveText(
      "Failed to update custom words. Please try again.",
    );
    await expect(wordInput(page)).toHaveValue("New term");
    await expect(
      page.getByRole("button", { name: "Remove Existing" }),
    ).toBeVisible();
    expect(
      await page.evaluate(() => localStorage.getItem("custom-words")),
    ).toBe('["Existing"]');
  });
}

test("locks dictionary add and remove controls during a shared update", async ({
  page,
}) => {
  await mount(page, ["Existing"]);
  await page.evaluate(() => localStorage.setItem("word-pending", "yes"));
  await wordInput(page).fill("New term");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(wordInput(page)).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Add", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Remove Existing" }),
  ).toBeDisabled();
  await page.evaluate(() =>
    (window as unknown as { finishWordUpdate: () => void }).finishWordUpdate(),
  );
  await expect(
    page.getByRole("button", { name: "Remove New term" }),
  ).toBeVisible();
});

test("store rejects a competing vocabulary write while one is pending", async ({
  page,
}) => {
  await mount(page);
  await page.evaluate(() => localStorage.setItem("word-pending", "yes"));
  const outcome = page.evaluate(async () => {
    const result = await (
      window as unknown as {
        updateWordsTwice: () => Promise<PromiseSettledResult<void>[]>;
      }
    ).updateWordsTwice();
    return result.map((item) => item.status);
  });
  await expect
    .poll(() => page.evaluate(() => localStorage.getItem("word-pending")))
    .toBe("yes");
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          typeof (window as unknown as { finishWordUpdate?: unknown })
            .finishWordUpdate,
      ),
    )
    .toBe("function");
  await page.evaluate(() =>
    (window as unknown as { finishWordUpdate: () => void }).finishWordUpdate(),
  );
  expect(await outcome).toEqual(["fulfilled", "rejected"]);
  expect(await page.evaluate(() => localStorage.getItem("custom-words"))).toBe(
    '["first"]',
  );
});

test("unrelated setting rollback preserves confirmed vocabulary", async ({
  page,
}) => {
  await mount(page, ["Existing"]);
  const pending = page.evaluate(() =>
    (
      window as unknown as { beginAudioUpdate: () => Promise<void> }
    ).beginAudioUpdate(),
  );
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          typeof (window as unknown as { failAudioUpdate?: unknown })
            .failAudioUpdate,
      ),
    )
    .toBe("function");
  await wordInput(page).fill("Confirmed term");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Remove Confirmed term" }),
  ).toBeVisible();
  await page.evaluate(() =>
    (window as unknown as { failAudioUpdate: () => void }).failAudioUpdate(),
  );
  await pending;
  await expect(
    page.getByRole("button", { name: "Remove Confirmed term" }),
  ).toBeVisible();
  expect(
    await page.evaluate(() =>
      (
        window as unknown as {
          readSettings: () => {
            audio_feedback: boolean;
            custom_words: string[];
          };
        }
      ).readSettings(),
    ),
  ).toEqual({
    audio_feedback: false,
    custom_words: ["Existing", "Confirmed term"],
  });
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Remove Confirmed term" }),
  ).toBeVisible();
});

for (const failure of ["result", "invoke"]) {
  test(`preserves a dictionary word after ${failure} removal failure and removes it on retry and reload`, async ({
    page,
  }) => {
    await mount(page, ["Keep", "Remove me"]);
    const remove = page.getByRole("button", {
      name: "Remove Remove me",
      exact: true,
    });
    await page.evaluate(
      (mode) => localStorage.setItem("word-failure", mode),
      failure,
    );
    await remove.click();
    await expect(page.getByRole("alert")).toHaveText(
      "Failed to update custom words. Please try again.",
    );
    await expect(remove).toBeEnabled();
    expect(
      await page.evaluate(() => localStorage.getItem("custom-words")),
    ).toBe('["Keep","Remove me"]');
    await page.reload();
    await expect(remove).toBeVisible();
    await page.evaluate(() => localStorage.removeItem("word-failure"));
    await remove.click();
    await expect(remove).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Remove Keep", exact: true }),
    ).toBeVisible();
    await expect(page.getByRole("alert")).toHaveCount(0);
    await page.reload();
    await expect(remove).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Remove Keep", exact: true }),
    ).toBeVisible();
    expect(
      await page.evaluate(() => localStorage.getItem("custom-words")),
    ).toBe('["Keep"]');
  });
}

test("normalization preserves mixed Chinese, Latin case and combining marks", () => {
  expect(normalizeCustomWord("  <言语>\u3000\"Acme\"\t\n'Cafe\u0301'  ")).toBe(
    "言语 Acme Cafe\u0301",
  );
  expect(
    getCustomWordValidationError("  <言语>\u3000\"Acme\"\t\n'Cafe\u0301'  "),
  ).toBeNull();
});

test("measures normalized supplementary characters in UTF-16 units", () => {
  const twentyFive = "😀".repeat(25);
  expect(getCustomWordValidationError(twentyFive)).toBeNull();
  expect(getCustomWordValidationError("😀".repeat(26))).toBe("tooLong");
  expect(getCustomWordValidationError(`  <"${twentyFive}">  `)).toBeNull();
  expect(normalizeCustomWord(`  <"${twentyFive}">  `)).toBe(twentyFive);
});

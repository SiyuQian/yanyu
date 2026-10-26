import { test, expect } from "@playwright/test";
import type { ModelInfo } from "../src/bindings";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const settings = {
      onboarding_completed: true,
      app_language: "en",
      keyboard_implementation: "tauri",
      shortcut_activation: "hold_or_toggle",
      selected_microphone: "Default",
      selected_output_device: "Default",
      selected_language: "auto",
      audio_feedback: false,
      audio_feedback_volume: 1,
      custom_words: JSON.parse(localStorage.getItem("custom-words") || "[]"),
      bindings: Object.fromEntries(
        ["transcribe", "cancel"].map((id) => [
          id,
          {
            id,
            name: id,
            description: id,
            current_binding: id === "transcribe" ? "alt" : "escape",
            default_binding: id === "transcribe" ? "alt" : "escape",
          },
        ]),
      ),
    };
    const model = {
      id: "qwen3",
      name: "Qwen3-ASR 0.6B",
      description: "",
      filename: "qwen3-asr-Q8_0.gguf",
      source: {
        Url: { url: "https://example.invalid/qwen3.gguf", sha256: null },
      },
      size_mb: 600,
      is_downloaded: true,
      is_downloading: false,
      partial_size: 0,
      is_directory: false,
      engine_type: "TranscribeCpp",
      accuracy_score: 0.8,
      speed_score: 0.8,
      is_recommended: false,
      is_custom: false,
      supports_streaming: false,
      supports_language_selection: true,
      supports_language_detection: true,
      supports_translation: false,
      supported_languages: ["en", "zh"],
    } satisfies ModelInfo;
    Object.assign(window, {
      __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
      __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
      __TAURI_INTERNALS__: {
        transformCallback: () => 1,
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "get_app_settings") return settings;
          if (command === "get_history_entries")
            return {
              entries: [
                {
                  id: 1,
                  file_name: "synthetic.wav",
                  timestamp: 100,
                  saved: false,
                  title: "Synthetic recording",
                  transcription_text: "recognized source",
                  post_processed_text: null,
                  post_process_prompt: null,
                  post_process_requested: false,
                  post_process_skip_reason: null,
                  user_corrected_text: "言语 Acme",
                },
              ],
              has_more: false,
            };
          if (command === "update_custom_words") {
            settings.custom_words = args.words as string[];
            localStorage.setItem("custom-words", JSON.stringify(args.words));
          }
          if (command === "get_available_models") return [model];
          if (command === "get_current_model") return model.id;
          if (command === "plugin:app|version") return "0.0.1";
          if (command.includes("check_")) return true;
          if (command === "get_microphone_channels") return 1;
          if (
            command === "get_audio_devices" ||
            command === "get_output_devices"
          )
            return [{ name: "Default", is_default: true }];
          if (command === "change_audio_feedback_setting") {
            settings.audio_feedback = args.enabled as boolean;
          }
          return null;
        },
      },
    });
  });
  await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `
        import React from '/node_modules/.vite/deps/react.js';
        import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
        import App from '/src/App.tsx';
        import { useSettingsStore } from '/src/stores/settingsStore.ts';
        import { useModelStore } from '/src/stores/modelStore.ts';
        import '/src/i18n/index.ts';
        const invoke = window.__TAURI_INTERNALS__.invoke;
        useSettingsStore.setState({
          settings: await invoke('get_app_settings'), isLoading: false,
          audioDevices: [{name: 'Default', is_default: true}],
          outputDevices: [{name: 'Default', is_default: true}],
          updateChecksLocked: false,
        });
        useModelStore.setState({
          models: await invoke('get_available_models'), currentModel: 'qwen3',
          initialized: true, loading: false,
        });
        ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(App));
      `,
    }),
  );
  await page.goto("/");
});

test("sidebar supports keyboard navigation and exposes the active page", async ({
  page,
}) => {
  const dictation = page.getByRole("button", {
    name: "Dictation",
    exact: true,
  });
  await expect(dictation).toHaveAttribute("aria-current", "page");
  const dictionary = page.getByRole("button", {
    name: "Dictionary",
    exact: true,
  });
  await dictionary.focus();
  await page.keyboard.press("Enter");
  await expect(dictionary).toHaveAttribute("aria-current", "page");
  await expect(dictation).not.toHaveAttribute("aria-current", "page");
  await expect(
    page.getByRole("heading", { name: "Transcribe Shortcut", exact: true }),
  ).toHaveCount(0);
  await dictation.focus();
  await page.keyboard.press("Space");
  await expect(
    page.getByRole("heading", { name: "Transcribe Shortcut", exact: true }),
  ).toBeVisible();
});

test("model action buttons have a comfortable target and visible keyboard focus", async ({
  page,
}, testInfo) => {
  await page.getByRole("button", { name: "Models", exact: true }).click();
  const rescan = page.getByRole("button", { name: /rescan/i });
  const bounds = await rescan.boundingBox();
  expect(bounds).not.toBeNull();
  expect(bounds!.width).toBeGreaterThanOrEqual(36);
  expect(bounds!.height).toBeGreaterThanOrEqual(36);
  await rescan.focus();
  expect(
    await rescan.evaluate((button) => getComputedStyle(button).outlineWidth),
  ).not.toBe("0px");
  await page.evaluate(() => {
    document.documentElement.dataset.theme = "dark";
  });
  await rescan.hover();
  await page.screenshot({
    path: testInfo.outputPath("model-actions-dark.png"),
    animations: "disabled",
  });
});

test("dictionary action buttons are visible in both themes", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1120, height: 780 });
  await page.getByRole("button", { name: "Dictionary", exact: true }).click();
  expect(
    (await page.locator(".settings-card").first().boundingBox())!.height,
  ).toBeGreaterThanOrEqual(190);
  const input = page.getByPlaceholder("Add a word");
  await input.fill("Acme");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByRole("button", { name: "Remove Acme" })).toBeVisible();
  await input.fill("Yanyu");
  const add = page.getByRole("button", { name: "Add", exact: true });
  await expect(add).toBeEnabled();
  expect((await add.boundingBox())!.width).toBeGreaterThanOrEqual(80);
  await expect(add.locator("svg")).toHaveCount(1);
  await input.evaluate((element) => element.blur());
  for (const theme of ["light", "dark"]) {
    await page.evaluate((value) => {
      document.documentElement.dataset.theme = value;
    }, theme);
    await page.waitForTimeout(200);
    expect(await add.evaluate((button) => getComputedStyle(button).color)).toBe(
      "rgb(255, 255, 255)",
    );
    await page.screenshot({
      path: testInfo.outputPath(`dictionary-buttons-${theme}.png`),
    });
  }
  await page.setViewportSize({ width: 680, height: 570 });
  const titleBounds = await page
    .getByRole("heading", { name: "Custom Words" })
    .boundingBox();
  const inputBounds = await input.boundingBox();
  expect(inputBounds!.y).toBeGreaterThan(titleBounds!.y + titleBounds!.height);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: testInfo.outputPath("dictionary-narrow-dark.png"),
  });
  await page.evaluate(async () => {
    const i18n = await import("/src/i18n/index.ts");
    await i18n.default.changeLanguage("zh");
  });
  await expect(page.getByRole("heading", { name: "自定义词汇" })).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.screenshot({
    path: testInfo.outputPath("dictionary-narrow-zh-dark.png"),
  });
  const longWord = "中".repeat(50);
  await page.locator(".dictionary-input").fill(longWord);
  await page.getByRole("button", { name: "添加", exact: true }).click();
  await expect(
    page.getByRole("button", { name: `删除 ${longWord}` }),
  ).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  await page.evaluate(async () => {
    const i18n = await import("/src/i18n/index.ts");
    await i18n.default.changeLanguage("ar");
  });
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
});

test("each workspace page retains its title while its content scrolls", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1120, height: 780 });
  for (const name of [
    "Dictation",
    "Dictionary",
    "Insights",
    "Style",
    "Models",
    "Advanced",
    "About",
  ]) {
    await page.getByRole("button", { name, exact: true }).click();
    const title = page.getByRole("heading", { name, level: 1, exact: true });
    await expect(title).toBeVisible();
    await page
      .locator("main")
      .getByRole("heading")
      .last()
      .scrollIntoViewIfNeeded();
    await expect(title).toBeInViewport();
    expect(await page.evaluate(() => window.scrollY)).toBe(0);
    await page.locator(".workspace-scroll").evaluate((el) => el.scrollTo(0, 0));
    await page.screenshot({
      path: testInfo.outputPath(`workspace-${name.toLowerCase()}.png`),
      animations: "disabled",
    });
  }
});

test("dictation keeps controls reachable in a narrow window in both themes", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 680, height: 570 });
  for (const theme of ["dark", "light"]) {
    await page.evaluate((theme) => {
      document.documentElement.dataset.theme = theme;
    }, theme);
    await expect(
      page.getByRole("heading", { name: "Dictation", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByRole("button", { name: "Add shortcut", exact: true }),
    ).toBeVisible();
    const volume = page.locator('input[type="range"]');
    await volume.scrollIntoViewIfNeeded();
    await expect(volume).toBeDisabled();
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
    const bounds = await volume.boundingBox();
    expect(bounds!.x).toBeGreaterThanOrEqual(0);
    expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(680);
    await page.screenshot({
      path: testInfo.outputPath(`narrow-${theme}.png`),
      animations: "disabled",
    });
  }
  await page
    .getByRole("checkbox", { name: "Audio Feedback", exact: true })
    .press("Space");
  await expect(
    page.getByRole("slider", { name: "Volume", exact: true }),
  ).toBeEnabled();
  await expect(
    page.getByText(
      "Enable audio feedback to adjust playback device and volume.",
    ),
  ).toHaveCount(0);
  await page
    .getByRole("checkbox", { name: "Audio Feedback", exact: true })
    .press("Space");
  await page.setViewportSize({ width: 1120, height: 780 });
  await page.evaluate(async () => {
    document.documentElement.dataset.theme = "dark";
    const i18n = await import("/src/i18n/index.ts");
    await i18n.default.changeLanguage("zh");
  });
  await expect(
    page.getByRole("heading", { name: "听写", exact: true }),
  ).toBeVisible();
  await page.locator(".workspace-scroll").evaluate((el) => el.scrollTo(0, 0));
  for (const theme of ["dark", "light"]) {
    await page.evaluate((theme) => {
      document.documentElement.dataset.theme = theme;
    }, theme);
    await page.screenshot({
      path: testInfo.outputPath(`dictation-zh-${theme}.png`),
      animations: "disabled",
    });
  }
  await page.setViewportSize({ width: 680, height: 570 });
  await page.evaluate(async () => {
    const i18n = await import("/src/i18n/index.ts");
    await i18n.default.changeLanguage("ar");
  });
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  await page.getByRole("slider").scrollIntoViewIfNeeded();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBe(true);
  const rtlBounds = await page.getByRole("slider").boundingBox();
  expect(rtlBounds!.x).toBeGreaterThanOrEqual(0);
  expect(rtlBounds!.x + rtlBounds!.width).toBeLessThanOrEqual(680);
});

test("history vocabulary is shared with Dictionary in App and survives reload", async ({
  page,
}) => {
  await page.getByRole("button", { name: "Insights", exact: true }).click();
  const correction = page.getByRole("textbox", {
    name: "Saved corrected transcript",
    exact: true,
  });
  await expect(correction).toHaveValue("言语 Acme");
  await correction.focus();
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Tab");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("status")).toHaveText("Added to vocabulary.");
  await page.getByRole("button", { name: "Dictionary", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Remove 言语 Acme", exact: true }),
  ).toBeVisible();
  await page.reload();
  await page.getByRole("button", { name: "Dictionary", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Remove 言语 Acme", exact: true }),
  ).toBeVisible();
});

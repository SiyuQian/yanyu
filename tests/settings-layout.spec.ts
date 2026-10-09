import { test, expect } from "@playwright/test";

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
      custom_words: [],
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
      is_downloaded: true,
      supports_language_selection: true,
      supports_language_detection: true,
      supports_translation: false,
      supported_languages: ["en", "zh"],
    };
    Object.assign(window, {
      __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
      __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
      __TAURI_INTERNALS__: {
        transformCallback: () => 1,
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "get_app_settings") return settings;
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
  await page.setViewportSize({ width: 1100, height: 900 });
  await page.evaluate(async () => {
    document.documentElement.dataset.theme = "dark";
    const i18n = await import("/src/i18n/index.ts");
    await i18n.default.changeLanguage("zh");
  });
  await expect(
    page.getByRole("heading", { name: "听写", exact: true }),
  ).toBeVisible();
  await page
    .getByRole("heading", { name: "听写", exact: true })
    .scrollIntoViewIfNeeded();
  await page.screenshot({
    path: testInfo.outputPath("dictation-zh-dark.png"),
    animations: "disabled",
  });
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

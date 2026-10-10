import { test, expect } from "@playwright/test";

test("a learned vocabulary notification refreshes settings before the next edit", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const callbacks = new Map<number, (event: unknown) => void>();
    const listeners = new Map<string, number>();
    let nextCallback = 0;
    let settings = { custom_words: ["existing"] };
    Object.assign(window, {
      __TAURI_INTERNALS__: {
        transformCallback: (callback: (event: unknown) => void) => {
          callbacks.set(++nextCallback, callback);
          return nextCallback;
        },
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "plugin:event|listen") {
            listeners.set(args.event as string, args.handler as number);
            return args.handler;
          }
          if (
            command === "get_app_settings" ||
            command === "get_default_settings"
          )
            return settings;
          if (command === "update_custom_words") {
            settings = { custom_words: args.words as string[] };
            return null;
          }
          if (command === "check_custom_sounds")
            return { start: false, stop: false };
          if (command === "is_update_checks_locked") return false;
          if (command === "test_learned_word") {
            settings = { custom_words: ["existing", "learned"] };
            const handler = listeners.get("settings-changed");
            if (handler === undefined)
              throw new Error("Missing settings listener");
            callbacks.get(handler)?.({ payload: { setting: "custom_words" } });
            return null;
          }
          return null;
        },
      },
    });
  });
  await page.goto("/src/correction/index.html");
  const words = await page.evaluate(async () => {
    const modulePath = "/src/stores/settingsStore.ts";
    const { useSettingsStore } = await import(/* @vite-ignore */ modulePath);
    await useSettingsStore.getState().initialize();
    const runtime = (
      window as unknown as {
        __TAURI_INTERNALS__: {
          invoke: (command: string, args: object) => Promise<unknown>;
        };
      }
    ).__TAURI_INTERNALS__;
    await runtime.invoke("test_learned_word", {});
    // The real store refresh is asynchronous, as it is across native windows.
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
    const words = useSettingsStore.getState().getSetting("custom_words");
    await useSettingsStore
      .getState()
      .updateSetting("custom_words", [...words, "next"]);
    return useSettingsStore.getState().getSetting("custom_words");
  });
  expect(words).toEqual(["existing", "learned", "next"]);
});

test("general settings changes, persists and resets the correct-last shortcut", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const binding = (id: string, current: string, fallback: string) => ({
      id,
      name: id,
      description: id,
      current_binding: current,
      default_binding: fallback,
    });
    const defaults = {
      transcribe: binding("transcribe", "alt", "alt"),
      cancel: binding("cancel", "escape", "escape"),
      correct_last: binding(
        "correct_last",
        "command+option+shift+c",
        "command+option+shift+c",
      ),
    };
    // The saved binding survives reloads like the persisted settings store.
    const saved = JSON.parse(
      localStorage.getItem("correct-last-test-bindings") ??
        JSON.stringify({
          ...defaults,
          correct_last: binding(
            "correct_last",
            "ctrl+shift+f9",
            "command+option+shift+c",
          ),
        }),
    );
    const calls: unknown[] = JSON.parse(
      localStorage.getItem("correct-last-test-calls") ?? "[]",
    );
    const persist = () => {
      localStorage.setItem("correct-last-test-bindings", JSON.stringify(saved));
      localStorage.setItem("correct-last-test-calls", JSON.stringify(calls));
    };
    const settings = () => ({
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
      bindings: saved,
    });
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
      __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "linux", platform: "linux" },
      __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
      __TAURI_INTERNALS__: {
        transformCallback: () => 1,
        invoke: async (command: string, args: Record<string, string>) => {
          if (command === "get_app_settings") return settings();
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
          if (command === "change_binding") {
            calls.push([command, args.id, args.binding]);
            saved[args.id] = {
              ...saved[args.id],
              current_binding: args.binding,
            };
            persist();
            return { success: true, binding: saved[args.id], error: null };
          }
          if (command === "reset_binding") {
            calls.push([command, args.id]);
            saved[args.id] = { ...defaults[args.id as keyof typeof defaults] };
            persist();
            return { success: true, binding: saved[args.id], error: null };
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
  await expect(
    page.getByText("Correct last dictation", { exact: true }),
  ).toBeVisible();
  const shortcut = page.getByRole("button", {
    name: "Ctrl + Shift + F9",
    exact: true,
  });
  await expect(shortcut).toBeVisible();

  await shortcut.click();
  await page.keyboard.press("Control+Shift+k");
  await expect(
    page.getByRole("button", { name: "Ctrl + Shift + K", exact: true }),
  ).toBeVisible();
  await page.reload();
  await expect(
    page.getByRole("button", { name: "Ctrl + Shift + K", exact: true }),
  ).toBeVisible();

  const row = page
    .getByText("Correct last dictation", { exact: true })
    .locator(
      "xpath=ancestor::*[.//button[contains(@class, 'reset-button')]][1]",
    );
  await row.locator(".reset-button").click();
  await expect(
    page.getByRole("button", { name: "Ctrl + Shift + K", exact: true }),
  ).toHaveCount(0);
  await expect(
    row.getByRole("button", {
      name: "Command + Option + Shift + C",
      exact: true,
    }),
  ).toBeVisible();
  expect(
    await page.evaluate(() =>
      JSON.parse(localStorage.getItem("correct-last-test-calls") ?? "[]"),
    ),
  ).toEqual([
    ["change_binding", "correct_last", "ctrl+shift+k"],
    ["reset_binding", "correct_last"],
  ]);
});

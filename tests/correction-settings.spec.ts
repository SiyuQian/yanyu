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

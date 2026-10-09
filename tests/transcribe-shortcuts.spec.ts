import { test, expect, type Page } from "@playwright/test";

for (const implementation of ["tauri", "handy_keys"]) {
  test.describe(implementation, () => {
    const capture = async (page: Page, keys: string) => {
      if (implementation === "tauri") {
        await page.keyboard.press(keys);
      } else {
        await page.waitForFunction(
          () =>
            (window as unknown as { shortcutListenerReady: boolean })
              .shortcutListenerReady,
        );
        await page.evaluate(async (keys) => {
          const emit = (
            window as unknown as {
              emitShortcut: (payload: unknown) => Promise<void>;
            }
          ).emitShortcut;
          const parts = keys.toLowerCase().split("+");
          const key = parts.pop()!;
          const hotkey_string = keys.toLowerCase().replace("control", "ctrl");
          await emit({
            modifiers: parts,
            key,
            is_key_down: true,
            hotkey_string,
          });
          await emit({
            modifiers: parts,
            key,
            is_key_down: false,
            hotkey_string,
          });
        }, keys);
      }
    };

    test.beforeEach(async ({ page }) => {
      await page.addInitScript((implementation) => {
        const binding = {
          id: "transcribe",
          name: "Transcribe",
          description: "Converts your speech into text.",
          default_binding: "ctrl+space",
          current_binding: "ctrl+space",
        };
        const settings = JSON.parse(
          localStorage.getItem("shortcut-test-settings") ||
            JSON.stringify({
              keyboard_implementation: implementation,
              bindings: { transcribe: binding },
            }),
        );
        const callbacks = new Map<number, (event: unknown) => Promise<void>>();
        let nextCallback = 0;
        let shortcutListener = 0;
        Object.assign(window, {
          shortcutListenerReady: false,
          emitShortcut: async (payload: unknown) => {
            await callbacks.get(shortcutListener)?.({
              event: "handy-keys-event",
              payload,
            });
          },
          __TAURI_EVENT_PLUGIN_INTERNALS__: {
            unregisterListener: (_event: string, id: number) => {
              callbacks.delete(id);
              if (id === shortcutListener) {
                Object.assign(window, { shortcutListenerReady: false });
              }
            },
          },
          __TAURI_OS_PLUGIN_INTERNALS__: {
            os_type: "linux",
            platform: "linux",
          },
          __TAURI_INTERNALS__: {
            transformCallback: (
              callback: (event: unknown) => Promise<void>,
            ) => {
              const id = ++nextCallback;
              callbacks.set(id, callback);
              return id;
            },
            invoke: async (command: string, args: Record<string, string>) => {
              if (command === "plugin:event|listen") {
                if (args.event === "handy-keys-event") {
                  shortcutListener = Number(args.handler);
                  Object.assign(window, { shortcutListenerReady: true });
                }
                return Number(args.handler);
              }
              if (command === "get_app_settings") return settings;
              if (command === "change_binding") {
                if (
                  Object.values(settings.bindings).some(
                    (b: unknown) =>
                      (b as typeof binding).id !== args.id &&
                      (b as typeof binding).current_binding === args.binding,
                  )
                ) {
                  return {
                    success: false,
                    error: "Shortcut is already in use",
                    binding: null,
                  };
                }
                settings.bindings[args.id] = {
                  ...binding,
                  ...settings.bindings[args.id],
                  id: args.id,
                  current_binding: args.binding,
                  default_binding:
                    settings.bindings[args.id]?.default_binding || args.binding,
                };
                localStorage.setItem(
                  "shortcut-test-settings",
                  JSON.stringify(settings),
                );
                return {
                  success: true,
                  binding: settings.bindings[args.id],
                  error: null,
                };
              }
              if (command === "remove_transcribe_binding") {
                delete settings.bindings[args.id];
                localStorage.setItem(
                  "shortcut-test-settings",
                  JSON.stringify(settings),
                );
              }
              return null;
            },
          },
        });
      }, implementation);
      await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
        route.fulfill({
          contentType: "application/javascript",
          body: `
        import React from '/node_modules/.vite/deps/react.js';
        import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
        import { ShortcutInput } from '/src/components/settings/ShortcutInput.tsx';
        import { useSettingsStore } from '/src/stores/settingsStore.ts';
        import '/src/i18n/index.ts';
        import '/src/App.css';
        const settings = await window.__TAURI_INTERNALS__.invoke('get_app_settings');
        useSettingsStore.setState({ settings, isLoading: false });
        ReactDOM.createRoot(document.getElementById('root')).render(
          React.createElement(ShortcutInput, { shortcutId: 'transcribe', grouped: true })
        );
      `,
        }),
      );
      await page.goto("/");
    });

    test("add, edit, reload and remove an additional transcribe shortcut", async ({
      page,
    }) => {
      await page
        .getByRole("button", { name: "Add shortcut", exact: true })
        .click();
      await capture(page, "Control+Shift+k");
      await expect(
        page.getByRole("button", { name: "Ctrl + Shift + K", exact: true }),
      ).toBeVisible();
      await page.reload();
      await page
        .getByRole("button", { name: "Ctrl + Shift + K", exact: true })
        .click();
      await capture(page, "Control+Shift+j");
      await expect(
        page.getByRole("button", { name: "Ctrl + Shift + J", exact: true }),
      ).toBeVisible();
      await page.getByRole("button", { name: "Remove shortcut" }).click();
      await expect(
        page.getByRole("button", { name: "Ctrl + Shift + J", exact: true }),
      ).toHaveCount(0);
      await expect(
        page.getByRole("button", { name: "Ctrl + Space", exact: true }),
      ).toBeVisible();
      await page.reload();
      await expect(
        page.getByRole("button", { name: "Remove shortcut" }),
      ).toHaveCount(0);
    });

    test("a failed addition keeps the existing shortcut and allows retry", async ({
      page,
    }) => {
      await page
        .getByRole("button", { name: "Add shortcut", exact: true })
        .click();
      await capture(page, "Control+Space");
      await expect(
        page.getByRole("button", { name: "Remove shortcut" }),
      ).toHaveCount(0);
      await page
        .getByRole("button", { name: "Add shortcut", exact: true })
        .click();
      await capture(page, "Control+Shift+k");
      await expect(
        page.getByRole("button", { name: "Ctrl + Shift + K", exact: true }),
      ).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Ctrl + Space", exact: true }),
      ).toBeVisible();
    });
  });
}

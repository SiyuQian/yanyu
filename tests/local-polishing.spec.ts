import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const settings = JSON.parse(
      localStorage.getItem("local-polishing-test") ||
        '{"local_polishing_enabled":false,"post_process_enabled":false}',
    );
    let phase = "missing";
    let supported =
      localStorage.getItem("local-polishing-supported") !== "false";
    Object.assign(window, {
      __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
      __TAURI_INTERNALS__: {
        invoke: async (command: string, args?: { enabled: boolean }) => {
          if (command === "get_app_settings") return settings;
          if (command === "get_local_polishing_status") {
            return {
              phase,
              progress: phase === "downloading" ? 0.5 : 0,
              error: null,
              downloaded: false,
              supported,
            };
          }
          if (command === "set_local_polishing_enabled") {
            settings.local_polishing_enabled = args?.enabled ?? false;
            localStorage.setItem(
              "local-polishing-test",
              JSON.stringify(settings),
            );
          }
          if (command === "download_local_polishing_model")
            phase = "downloading";
          if (command === "cancel_local_polishing_download") phase = "missing";
          if (command === "delete_local_polishing_model") {
            settings.local_polishing_enabled = false;
            phase = "missing";
          }
          if (command === "change_post_process_enabled_setting")
            throw new Error("Legacy postprocessing must remain unchanged");
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
      import { AdvancedSettings } from '/src/components/settings/advanced/AdvancedSettings.tsx';
      import { LocalPolishingSettings } from '/src/components/settings/general/LocalPolishingSettings.tsx';
      import { useSettingsStore } from '/src/stores/settingsStore.ts';
      import '/src/i18n/index.ts';
      import '/src/App.css';
      const settings = await window.__TAURI_INTERNALS__.invoke('get_app_settings');
      useSettingsStore.setState({ settings, isLoading: false });
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(React.Fragment, null, React.createElement(AdvancedSettings), React.createElement(LocalPolishingSettings)));
    `,
    }),
  );
  await page.goto("/");
});

test("polishing is accessible and uses the unified setting in the custom prompt group", async ({
  page,
}) => {
  const toggle = page.getByRole("checkbox", {
    name: "Process Voice Input with selected prompt",
  });
  await expect(toggle).not.toBeChecked();
  await toggle.focus();
  await page.keyboard.press("Space");
  await expect(toggle).toBeChecked();
  await page.reload();
  await expect(toggle).toBeChecked();
});

test("prompt toggle is disabled when local polishing is unsupported", async ({
  page,
}) => {
  await page.evaluate(() =>
    localStorage.setItem("local-polishing-supported", "false"),
  );
  await page.reload();
  await expect(
    page.getByRole("checkbox", {
      name: "Process Voice Input with selected prompt",
    }),
  ).toBeDisabled();
});

test("download progress and cancellation are reachable while polishing is off", async ({
  page,
}) => {
  await page
    .getByRole("button", { name: "Download Qwen3-0.6B (651 MB)" })
    .click();
  await expect(
    page.getByRole("progressbar", { name: "Model download progress" }),
  ).toHaveAttribute("value", "0.5");
  await page.getByRole("button", { name: "Cancel download" }).click();
  await expect(page.getByRole("status")).toHaveText("Model not downloaded");
  await expect(
    page.getByRole("checkbox", {
      name: "Process Voice Input with selected prompt",
    }),
  ).not.toBeChecked();
});

import { expect, test } from "@playwright/test";

test("a retired selection stays unconfigured until the user picks a provider", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("i18nextLng", "en");
    const calls: string[] = [];
    Object.assign(window, {
      postProcessingCalls: calls,
      __TAURI_INTERNALS__: {
        async invoke(command: string, args?: { providerId?: string }) {
          calls.push(command);
          if (command === "get_app_settings") {
            return {
              app_language: "en",
              post_process_provider_id:
                localStorage.getItem("post-processing-provider") ??
                "apple_intelligence",
              post_process_providers: [
                {
                  id: "custom",
                  label: "Custom",
                  base_url: "http://127.0.0.1:1234/v1",
                  allow_base_url_edit: true,
                  models_endpoint: "/models",
                  supports_structured_output: false,
                },
              ],
              post_process_models: { custom: "fixture-model" },
            };
          }
          if (command === "set_post_process_provider" && args?.providerId) {
            localStorage.setItem("post-processing-provider", args.providerId);
          }
          if (command === "fetch_post_process_models") return ["fixture-model"];
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
        import { PostProcessingSettings } from '/src/components/settings/post-processing/PostProcessingSettings.tsx';
        import { useSettingsStore } from '/src/stores/settingsStore.ts';
        import '/src/i18n/index.ts';
        import '/src/App.css';
        const settings = await window.__TAURI_INTERNALS__.invoke('get_app_settings');
        useSettingsStore.setState({ settings, isLoading: false });
        ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(PostProcessingSettings));
      `,
    }),
  );
  await page.goto("/");

  const picker = page.getByRole("button", { name: "Select a provider" });
  const apiKeyLabel = page.getByText("API Key", { exact: true });
  for (const firstLoad of [true, false]) {
    if (!firstLoad) await page.reload();
    await expect(picker).toBeVisible();
    await expect(apiKeyLabel).toHaveCount(0);
    await expect(page.getByRole("combobox")).toHaveCount(0);
    const providerCalls = await page.evaluate(() =>
      Reflect.get(window, "postProcessingCalls").filter(
        (command: string) =>
          command === "set_post_process_provider" ||
          command === "fetch_post_process_models",
      ),
    );
    expect(providerCalls).toEqual([]);
  }

  await picker.click();
  await expect(
    page.getByRole("button", { name: "Apple Intelligence" }),
  ).toHaveCount(0);
  await page.getByRole("button", { name: "Custom" }).click();
  await expect(apiKeyLabel).toBeVisible();
  await page.reload();
  await expect(page.getByRole("button", { name: "Custom" })).toBeVisible();
  await expect(apiKeyLabel).toBeVisible();
});

import { test, expect } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const settings = JSON.parse(
      localStorage.getItem("profile-test") ||
        '{"personalization":{"enabled":false,"invitation_dismissed":false,"uses":[],"domain":null,"other_domain":""},"processing_mode":"legacy","post_process_prompts":[{"id":"saved","name":"Saved","prompt":"Translate to French"}],"post_process_selected_prompt_id":"saved"}',
    );
    Object.assign(window, {
      __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
      __TAURI_INTERNALS__: {
        invoke: async (
          command: string,
          args?: { profile?: unknown; mode?: string },
        ) => {
          if (command === "get_app_settings") {
            if (
              localStorage.getItem("reject-profile-refresh") &&
              settings.personalization.enabled
            )
              throw new Error("Refresh failed");
            return settings;
          }
          if (command === "get_personalization_status")
            return {
              service_ready: !!localStorage.getItem("ready-profile"),
              asr_ready: !!localStorage.getItem("ready-profile"),
              active: !!localStorage.getItem("ready-profile"),
            };
          if (command === "save_personalization") {
            if (localStorage.getItem("reject-profile"))
              throw new Error("Save rejected");
            settings.personalization = {
              ...(args?.profile as object),
              invitation_dismissed: true,
            };
            settings.processing_mode = "generated";
          }
          if (command === "dismiss_personalization_invitation")
            settings.personalization.invitation_dismissed = true;
          if (command === "delete_personalization")
            settings.personalization = {
              enabled: false,
              invitation_dismissed: true,
              uses: [],
              domain: null,
              other_domain: "",
            };
          if (command === "set_processing_mode")
            settings.processing_mode = args?.mode;
          if (
            command === "cancel_personalization_trial" &&
            localStorage.getItem("reject-trial-cancel")
          )
            throw new Error("Cancel rejected");
          if (command === "start_personalization_trial") {
            localStorage.setItem("trial-started", "true");
          }
          if (command === "stop_personalization_trial")
            return {
              original: "嗯，我我我想写代码，但不要改文件。",
              processed: "我想写代码，但不要改文件。",
              processing_succeeded: true,
            };
          if (
            command.includes("paste") ||
            command.includes("clipboard") ||
            command.includes("save_wav") ||
            command.includes("send_transcription_input")
          )
            throw new Error("Preview attempted external input or persistence");
          localStorage.setItem("profile-test", JSON.stringify(settings));
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
      import { GeneralSettings } from '/src/components/settings/general/GeneralSettings.tsx';
      import { useSettingsStore } from '/src/stores/settingsStore.ts';
      import '/src/i18n/index.ts';
      import '/src/App.css';
      const settings = await window.__TAURI_INTERNALS__.invoke('get_app_settings');
      useSettingsStore.setState({ settings, isLoading: false });
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(GeneralSettings));
    `,
    }),
  );
  await page.goto("/", { waitUntil: "domcontentloaded" });
});

test("optional invitation can be skipped once and reopened", async ({
  page,
}) => {
  await page.getByRole("button", { name: "Later" }).click();
  await page.reload();
  await expect(page.getByRole("button", { name: "Later" })).toHaveCount(0);
  await page.getByRole("button", { name: "Edit profile" }).click();
  await expect(
    page.getByRole("group", { name: "What do you mainly use Yanyu for?" }),
  ).toBeVisible();
});

test("keyboard questions save a pending profile without replacing legacy prompts", async ({
  page,
}) => {
  await page.getByRole("button", { name: "Set up personalization" }).click();
  const ai = page.getByRole("checkbox", { name: "Conversations with AI" });
  await ai.focus();
  await page.keyboard.press("Space");
  await page.getByRole("button", { name: "Review profile" }).click();
  await expect(
    page.getByText(/sends your transcript and selected profile context/),
  ).toBeVisible();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Saved; finish service setup" }),
  ).toContainText("Saved; finish service setup");
  await expect(
    page.getByRole("button", { name: "Record a trial" }),
  ).toBeDisabled();
  const saved = await page.evaluate(() =>
    JSON.parse(localStorage.getItem("profile-test")!),
  );
  expect(saved.post_process_prompts[0].prompt).toBe("Translate to French");
  await page.getByRole("button", { name: "Disable personalization" }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Disabled" }),
  ).toContainText("Disabled");
  await page.getByRole("button", { name: "Delete profile" }).click();
  await page.getByRole("button", { name: "Edit profile" }).click();
  await expect(ai).not.toBeChecked();
});

test("rejected save stays in review and reports the failure", async ({
  page,
}) => {
  await page.evaluate(() => localStorage.setItem("reject-profile", "true"));
  await page.getByRole("button", { name: "Set up personalization" }).click();
  await page.getByRole("button", { name: "Review profile" }).click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Save and enable" }),
  ).toBeVisible();
});

test("domain dropdown and optional details remain keyboard accessible", async ({
  page,
}) => {
  await page.getByRole("button", { name: "Set up personalization" }).click();
  const domain = page.getByRole("button", {
    name: "Which field do you mainly work or study in?",
  });
  await domain.focus();
  await page.keyboard.press("Enter");
  await page.getByRole("button", { name: "Other", exact: true }).click();
  await page
    .getByRole("textbox", { name: /Other field/ })
    .fill("Documentation");
  await page.getByRole("button", { name: "Review profile" }).click();
  await expect(page.getByText(/Documentation/)).toBeVisible();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await page.reload();
  await page.getByRole("button", { name: "Edit profile" }).click();
  await expect(page.getByRole("textbox", { name: /Other field/ })).toHaveValue(
    "Documentation",
  );
});

test("ready trial requires an explicit recording and shows a preview comparison", async ({
  page,
}) => {
  await page.evaluate(() => localStorage.setItem("ready-profile", "true"));
  await page.getByRole("button", { name: "Set up personalization" }).click();
  await page.getByRole("button", { name: "Review profile" }).click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  expect(
    await page.evaluate(() => localStorage.getItem("trial-started")),
  ).toBeNull();
  await page.getByRole("button", { name: "Record a trial" }).click();
  await page.getByRole("button", { name: "Stop and compare" }).click();
  await expect(
    page.getByText("嗯，我我我想写代码，但不要改文件。", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("我想写代码，但不要改文件。", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText(/This sample does not prove a general accuracy gain/),
  ).toBeVisible();
  await page.getByRole("button", { name: "Record a trial" }).click();
  await page.getByRole("button", { name: "Cancel trial" }).click();
  await expect(
    page.getByRole("button", { name: "Record a trial" }),
  ).toBeEnabled();
});

test("advanced prompts stay available while Generated profile is enabled", async ({
  page,
}) => {
  await page.evaluate(() => {
    const settings = JSON.parse(localStorage.getItem("profile-test")!);
    settings.processing_mode = "generated";
    settings.personalization.enabled = true;
    settings.personalization.invitation_dismissed = true;
    localStorage.setItem("profile-test", JSON.stringify(settings));
  });
  await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `
      import React from '/node_modules/.vite/deps/react.js';
      import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';
      import { AdvancedSettings } from '/src/components/settings/advanced/AdvancedSettings.tsx';
      import { useSettingsStore } from '/src/stores/settingsStore.ts';
      import '/src/i18n/index.ts';
      import '/src/App.css';
      const settings = await window.__TAURI_INTERNALS__.invoke('get_app_settings');
      useSettingsStore.setState({ settings, isLoading: false });
      ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(AdvancedSettings));
    `,
    }),
  );
  await page.reload({ waitUntil: "domcontentloaded" });
  await expect(page.locator("textarea")).toHaveValue("Translate to French");
  await expect(
    page.getByRole("checkbox", {
      name: "Process Voice Input with selected prompt",
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Use saved custom prompts" }),
  ).toHaveCount(0);
  await page.reload({ waitUntil: "domcontentloaded" });
  await expect(page.locator("textarea")).toHaveValue("Translate to French");
});

test("failed refresh after save does not display activation success", async ({
  page,
}) => {
  await page.evaluate(() =>
    localStorage.setItem("reject-profile-refresh", "true"),
  );
  await page.getByRole("button", { name: "Set up personalization" }).click();
  await page.getByRole("button", { name: "Review profile" }).click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Save and enable" }),
  ).toBeVisible();
});

test("failed trial cancellation remains visible and can be retried", async ({
  page,
}) => {
  await page.evaluate(() => localStorage.setItem("ready-profile", "true"));
  await page.getByRole("button", { name: "Set up personalization" }).click();
  await page.getByRole("button", { name: "Review profile" }).click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await page.getByRole("button", { name: "Record a trial" }).click();
  await page.getByRole("button", { name: "Stop and compare" }).waitFor();
  await page.evaluate(() =>
    localStorage.setItem("reject-trial-cancel", "true"),
  );
  await page.getByRole("button", { name: "Cancel trial" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Cancel trial" }),
  ).toBeVisible();
  await page.evaluate(() => localStorage.removeItem("reject-trial-cancel"));
  await page.getByRole("button", { name: "Cancel trial" }).click();
  await expect(
    page.getByRole("button", { name: "Record a trial" }),
  ).toBeEnabled();
});

test("trial starts when the native webview lacks randomUUID", async ({
  page,
}) => {
  await page.evaluate(() => {
    Object.defineProperty(window.crypto, "randomUUID", {
      value: undefined,
      configurable: true,
    });
    localStorage.setItem("ready-profile", "true");
  });
  await page.getByRole("button", { name: "Set up personalization" }).click();
  await page.getByRole("button", { name: "Review profile" }).click();
  await page.getByRole("button", { name: "Save and enable" }).click();
  await page.getByRole("button", { name: "Record a trial" }).click();
  await expect(
    page.getByRole("button", { name: "Stop and compare" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Cancel trial" }).click();
});

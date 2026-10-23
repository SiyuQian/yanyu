import { test, expect } from "@playwright/test";
import type { Page } from "@playwright/test";
async function mount(
  page: Page,
  missing = false,
  capture = false,
  fullApp = false,
) {
  await page.addInitScript(
    ({ missing, capture }) => {
      const initial = {
        version: 1,
        id: "0123456789abcdef0123456789abcdef",
        title: "Synthetic meeting",
        mode: "online",
        created_at: "2026-10-21T10:00:00Z",
        status: "complete",
        mic_frames: 160000,
        system_frames: 160000,
        duration_ms: 10000,
        completed_ms: 10000,
        transcript_complete: true,
        segments: [
          {
            id: "s0",
            start_ms: 2000,
            end_ms: 3000,
            text: "We decided to release Monday.",
            speaker: "speaker_1",
            uncertain: false,
          },
        ],
        speakers: { speaker_1: "Speaker A" },
        references: [],
        notes: "## Decisions\n\nRelease Monday",
        notes_stale: false,
        error: null,
      };
      let rows = JSON.parse(
        localStorage.getItem("meetings-fixture") || "null",
      ) || [initial];
      if (localStorage.getItem("fixture-many-meetings")) {
        rows = Array.from({ length: 53 }, (_, index) => ({
          ...initial,
          id: index.toString(16).padStart(32, "0"),
          title: `Meeting ${index}`,
          notes: `Details ${index}`,
        }));
      }
      Object.assign(window, {
        __TAURI_OS_PLUGIN_INTERNALS__: { os_type: "macos", platform: "macos" },
        __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
        __TAURI_INTERNALS__: {
          transformCallback: () => 1,
          convertFileSrc: (path: string) => path,
          invoke: async (command: string, args: Record<string, unknown>) => {
            if (command === "meeting_setup")
              return {
                available: true,
                moss_installed:
                  !missing && !localStorage.getItem("fixture-no-moss"),
                qwen_installed: !missing,
              };
            if (command === "meeting_list") {
              const offset = Number(args.offset || 0);
              return {
                items: rows
                  .slice(offset, offset + 50)
                  .map(
                    ({
                      id,
                      title,
                      created_at,
                      status,
                      duration_ms,
                      completed_ms,
                    }: typeof initial) => ({
                      id,
                      title,
                      created_at,
                      status,
                      duration_ms,
                      completed_ms,
                    }),
                  ),
                active: rows.filter((row: typeof initial) =>
                  [
                    "recording",
                    "paused",
                    "transcribing",
                    "summarizing",
                  ].includes(row.status),
                ),
                has_more: rows.length > offset + 50,
              };
            }
            if (command === "meeting_get")
              return rows.find((row: typeof initial) => row.id === args.id);
            if (command === "meeting_audio") return "/synthetic.wav";
            if (command === "meeting_edit") {
              const edited = args.meeting as typeof initial;
              rows = rows.map((row: typeof initial) =>
                row.id === edited.id ? edited : row,
              );
              localStorage.setItem("meetings-fixture", JSON.stringify(rows));
              return {
                ...edited,
                durability_warning: localStorage.getItem("fixture-sync-failure")
                  ? "injected directory sync failure"
                  : null,
              };
            }
            if (command === "meeting_export") {
              localStorage.setItem("meeting-export", JSON.stringify(rows[0]));
              return true;
            }
            if (command === "meeting_delete") {
              rows = [];
              localStorage.setItem("meetings-fixture", "[]");
              return null;
            }
            if (command === "meeting_start") {
              if (!capture) throw "microphone_permission_denied";
              const row = {
                ...initial,
                id: "abcdef0123456789abcdef0123456789",
                title: "Captured fixture",
                status: "recording",
                duration_ms: 0,
                completed_ms: 0,
                transcript_complete: false,
                segments: [],
                notes: "",
              };
              rows = [row, ...rows];
              return row;
            }
            if (command === "meeting_control") {
              rows = rows.map((row: typeof initial) =>
                row.id === args.id
                  ? {
                      ...row,
                      status:
                        args.action === "pause"
                          ? "paused"
                          : args.action === "resume"
                            ? "recording"
                            : "recorded",
                      duration_ms: 10000,
                    }
                  : row,
              );
              if (
                args.action === "stop" &&
                localStorage.getItem("fixture-incomplete-capture")
              )
                rows = rows.map((row: typeof initial) =>
                  row.id === args.id
                    ? {
                        ...row,
                        status: "recoverable",
                        error: "system_audio_interrupted",
                        capture_error: "system_audio_interrupted",
                      }
                    : row,
                );
              return null;
            }
            if (command === "meeting_process") {
              const retry = !!localStorage.getItem("meeting-process-attempt");
              localStorage.setItem("meeting-process-attempt", "1");
              rows = rows.map((row: typeof initial) =>
                row.id === args.id
                  ? {
                      ...row,
                      status: retry ? "complete" : "failed",
                      error: retry ? null : "fixture_processing_failure",
                      segments: retry ? initial.segments : [],
                      notes: retry ? "Locally generated fixture notes" : "",
                      transcript_complete: retry,
                    }
                  : row,
              );
              return null;
            }
            if (command === "get_app_settings")
              return {
                onboarding_completed: true,
                app_language: "en",
                bindings: {},
                custom_words: [],
                selected_microphone: "Default",
                selected_output_device: "Default",
                selected_language: "auto",
                keyboard_implementation: "tauri",
                shortcut_activation: "hold_or_toggle",
              };
            if (command.includes("check_")) return true;
            if (command === "get_available_models") return [];
            if (command === "plugin:app|version") return "0.0.1";
            if (
              command === "get_audio_devices" ||
              command === "get_output_devices"
            )
              return [{ name: "Default", is_default: true }];
            return null;
          },
        },
      });
    },
    { missing, capture },
  );
  await page.route(/\/src\/main\.tsx(?:\?.*)?$/, (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: fullApp
        ? `import React from '/node_modules/.vite/deps/react.js';import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';import App from '/src/App.tsx';import {useSettingsStore} from '/src/stores/settingsStore.ts';import {useModelStore} from '/src/stores/modelStore.ts';import '/src/i18n/index.ts';import '/src/App.css';useSettingsStore.setState({settings:await window.__TAURI_INTERNALS__.invoke("get_app_settings",{}),isLoading:false,audioDevices:[],outputDevices:[]});useModelStore.setState({models:[],initialized:true,loading:false});ReactDOM.createRoot(document.getElementById("root")).render(React.createElement(App));`
        : `import React from '/node_modules/.vite/deps/react.js';import ReactDOM from '/node_modules/.vite/deps/react-dom_client.js';import {MeetingsPage} from '/src/components/meetings/MeetingsPage.tsx';import '/src/i18n/index.ts';import '/src/App.css';ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(MeetingsPage));`,
    }),
  );
  const wav = Buffer.alloc(160044);
  wav.write("RIFF");
  wav.writeUInt32LE(160036, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(16000, 24);
  wav.writeUInt32LE(32000, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(160000, 40);
  await page.route("**/synthetic.wav", (route) =>
    route.fulfill({ contentType: "audio/wav", body: wav }),
  );
  await page.goto("/");
}
test("edits transcript and names, exports current notes, and deletes only after confirmation", async ({
  page,
}) => {
  await mount(page);
  await page
    .getByRole("button", { name: "Synthetic meeting", exact: true })
    .click();
  await page
    .getByRole("textbox", { name: "Transcript 00:02" })
    .fill("Corrected Monday decision");
  await page
    .getByRole("textbox", { name: "Speaker name speaker_1" })
    .fill("Alice");
  await page
    .getByRole("textbox", { name: "Meeting notes" })
    .fill("Current edited notes");
  await page.getByRole("button", { name: "Save changes" }).click();
  await page.reload();
  await page
    .getByRole("button", { name: "Synthetic meeting", exact: true })
    .click();
  await expect(
    page.getByRole("textbox", { name: "Transcript 00:02" }),
  ).toHaveValue("Corrected Monday decision");
  await expect(
    page.getByRole("textbox", { name: "Speaker name speaker_1" }),
  ).toHaveValue("Alice");
  await expect(page.getByLabel("Meeting recording")).toBeVisible();
  await page.getByRole("button", { name: "00:02", exact: true }).click();
  await expect
    .poll(() =>
      page
        .getByLabel("Meeting recording")
        .evaluate((element) => (element as HTMLAudioElement).currentTime),
    )
    .toBeGreaterThanOrEqual(2);
  if (process.env.MEETING_SCREENSHOT)
    await page.screenshot({
      path: process.env.MEETING_SCREENSHOT,
      fullPage: true,
    });
  await page.getByRole("button", { name: "Export Markdown" }).click();
  await expect
    .poll(() => page.evaluate(() => localStorage.getItem("meeting-export")))
    .toContain("Current edited notes");
  await page
    .getByRole("button", { name: "Delete meeting", exact: true })
    .click();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Synthetic meeting", exact: true }),
  ).toBeVisible();
  await page
    .getByRole("button", { name: "Delete meeting", exact: true })
    .click();
  await page.getByRole("button", { name: "Delete permanently" }).click();
  await expect(
    page.getByRole("button", { name: "Synthetic meeting", exact: true }),
  ).toHaveCount(0);
});
test("missing models and denied microphone show explicit local recovery guidance", async ({
  page,
}) => {
  await mount(page, true);
  await expect(page.getByText(/Install MOSS/)).toBeVisible();
  await page.getByRole("button", { name: "Start recording" }).click();
  await expect(page.getByRole("alert")).toContainText("Microphone");
  await expect(page.getByRole("alert")).toContainText("System Settings");
});

test("recording controls survive navigation and failed processing can retry", async ({
  page,
}) => {
  await mount(page, false, true, true);
  await page.getByRole("button", { name: "Meetings", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Meeting NoteTaker" }),
  ).toBeVisible();
  await page.getByLabel("Meeting mode").selectOption("online");
  await page.getByRole("button", { name: "Start recording" }).click();
  await expect(
    page.getByRole("button", { name: "Captured fixture", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Pause", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Resume", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Dictation", exact: true }).click();
  await page.getByRole("button", { name: "Meetings", exact: true }).click();
  await page.getByRole("button", { name: "Resume", exact: true }).click();
  await page.getByRole("button", { name: "End and process locally" }).click();
  await expect(page.getByRole("alert")).toBeVisible();
  await page.getByRole("button", { name: "Retry local processing" }).click();
  await expect(
    page.getByRole("textbox", { name: "Meeting notes" }),
  ).toHaveValue("Locally generated fixture notes");
});

test("incomplete capture requires explicit retry and stays visibly incomplete", async ({
  page,
}) => {
  await mount(page, false, true);
  await page.getByRole("button", { name: "Start recording" }).click();
  await page.evaluate(() =>
    localStorage.setItem("fixture-incomplete-capture", "1"),
  );
  await page.getByRole("button", { name: "End and process locally" }).click();
  await expect(
    page.getByText("This recording is incomplete.", { exact: false }),
  ).toBeVisible();
  expect(
    await page.evaluate(() => localStorage.getItem("meeting-process-attempt")),
  ).toBeNull();
  await page.getByRole("button", { name: "Retry local processing" }).click();
  await page.getByRole("button", { name: "Retry local processing" }).click();
  await expect(
    page.getByRole("textbox", { name: "Meeting notes" }),
  ).toHaveValue("Locally generated fixture notes");
  await expect(
    page.getByText("This recording is incomplete.", { exact: false }),
  ).toBeVisible();
});

test("regenerates_notes_without_moss_for_complete_transcript", async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem("fixture-no-moss", "1");
    localStorage.setItem("meeting-process-attempt", "1");
  });
  await mount(page);
  await page
    .getByRole("button", { name: "Regenerate local notes", exact: true })
    .click({ timeout: 3000 });
  await expect(
    page.getByRole("textbox", { name: "Meeting notes" }),
  ).toHaveValue("Locally generated fixture notes");
});

test("committed_edit_shows_durability_warning_without_retaining_dirty_draft", async ({
  page,
}) => {
  await page.addInitScript(() =>
    localStorage.setItem("fixture-sync-failure", "1"),
  );
  await mount(page);
  await page
    .getByRole("textbox", { name: "Meeting title", exact: true })
    .fill("Committed title");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText("The edit was saved");
  await expect(
    page.getByRole("button", { name: "Save changes", exact: true }),
  ).toBeDisabled();
  await page.reload();
  await expect(
    page.getByRole("textbox", { name: "Meeting title", exact: true }),
  ).toHaveValue("Committed title");
});

test("pages_through_retained_history_and_loads_selected_details", async ({
  page,
}) => {
  await page.addInitScript(() =>
    localStorage.setItem("fixture-many-meetings", "1"),
  );
  await mount(page);
  await expect(
    page.getByRole("button", { name: "Meeting 49", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Meeting 50", exact: true }),
  ).toHaveCount(0);
  await page
    .getByRole("button", { name: "Next meetings", exact: true })
    .click();
  await expect(
    page.getByRole("button", { name: "Meeting 50", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("textbox", { name: "Meeting notes", exact: true }),
  ).toHaveValue("Details 50");
  await expect(
    page.getByRole("button", { name: "Next meetings", exact: true }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "Previous meetings", exact: true })
    .click();
  await expect(
    page.getByRole("textbox", { name: "Meeting notes", exact: true }),
  ).toHaveValue("Details 0");
});

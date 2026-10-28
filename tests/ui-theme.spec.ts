import { test, expect, type Page } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light", reducedMotion: "reduce" });
  // Only the native event transport is replaced; styles and components are real.
  await page.addInitScript(() => {
    const callbacks = new Map<number, (event: unknown) => void>();
    let next = 0;
    let logListener = 0;
    Object.assign(window, {
      emitLog: () =>
        callbacks.get(logListener)?.({
          payload: { level: 2, message: "Theme diagnostic" },
        }),
      __TAURI_EVENT_PLUGIN_INTERNALS__: { unregisterListener: () => {} },
      __TAURI_INTERNALS__: {
        transformCallback: (callback: (event: unknown) => void) => {
          callbacks.set(++next, callback);
          return next;
        },
        invoke: async (command: string, args: Record<string, unknown>) => {
          if (command === "plugin:event|listen") {
            if (args.event === "log://log") logListener = Number(args.handler);
            return Number(args.handler);
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
        import { Input } from '/src/components/ui/Input.tsx';
        import { Textarea } from '/src/components/ui/Textarea.tsx';
        import { Alert } from '/src/components/ui/Alert.tsx';
        import { AudioPlayer } from '/src/components/ui/AudioPlayer.tsx';
        import { Dropdown } from '/src/components/ui/Dropdown.tsx';
        import { SettingsGroup } from '/src/components/ui/SettingsGroup.tsx';
        import { LiveLogViewer } from '/src/components/settings/debug/LiveLogViewer.tsx';
        import '/src/i18n/index.ts';
        import '/src/App.css';
        const h = React.createElement;
        ReactDOM.createRoot(document.getElementById('root')).render(
          h('main', { className: 'settings-shell min-h-screen p-4 space-y-4' },
            h(SettingsGroup, { title: 'Controls', variant: 'card' },
              h(Input, { 'aria-label': 'Single line' }),
              h(Textarea, { 'aria-label': 'Multiple lines' }),
              h(Textarea, { 'aria-label': 'Compact multiple lines', variant: 'compact' }),
              h(Input, { 'aria-label': 'Disabled input', disabled: true }),
              h(Textarea, { 'aria-label': 'Disabled textarea', disabled: true }),
              h(Dropdown, { options: [{ value: 'one', label: 'One' }], selectedValue: 'one', onSelect: () => {} }),
            ),
            h(Alert, { variant: 'error' }, 'Error notice'),
            h(Alert, { variant: 'warning' }, 'Warning notice'),
            h(AudioPlayer),
            h(LiveLogViewer, { descriptionMode: 'inline' }),
          ),
        );
      `,
    }),
  );
  await page.goto("/");
  await expect(page.getByLabel("Single line")).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(() => {
        (window as unknown as { emitLog: () => void }).emitLog();
        return document.body.textContent?.includes("Theme diagnostic");
      }),
    )
    .toBe(true);
});

async function setTheme(page: Page, theme: "system" | "light" | "dark") {
  await page.evaluate(async (value) => {
    const { applyTheme } = await import("/src/lib/utils/theme.ts");
    applyTheme(value);
  }, theme);
}

async function palette(page: Page) {
  return {
    logSurface: await page
      .locator(".font-mono.overflow-y-auto")
      .evaluate((el) => getComputedStyle(el).backgroundColor),
    logTag: await page
      .getByText("DEBUG", { exact: true })
      .first()
      .evaluate((el) => getComputedStyle(el).color),
    error: await page
      .getByText("Error notice", { exact: true })
      .evaluate((el) => getComputedStyle(el).color),
    warning: await page
      .getByText("Warning notice", { exact: true })
      .evaluate((el) => getComputedStyle(el).color),
  };
}

test("explicit themes keep log colors consistent when the OS theme differs", async ({
  page,
}) => {
  const light = await palette(page);
  await page.emulateMedia({ colorScheme: "dark" });
  const dark = await palette(page);
  expect(dark.logSurface).not.toBe(light.logSurface);
  expect(dark.logTag).not.toBe(light.logTag);

  await setTheme(page, "light");
  await expect.poll(() => palette(page)).toEqual(light);
  await setTheme(page, "dark");
  await page.emulateMedia({ colorScheme: "light" });
  await expect.poll(() => palette(page)).toEqual(dark);
  await setTheme(page, "system");
  await expect.poll(() => palette(page)).toEqual(light);
});

test("text controls share focus and disabled appearance in both themes", async ({
  page,
}) => {
  for (const theme of ["light", "dark"] as const) {
    await setTheme(page, theme);
    await page.getByRole("heading", { name: "Controls", exact: true }).click();
    const input = page.getByLabel("Single line", { exact: true });
    const textarea = page.getByLabel("Multiple lines", { exact: true });
    await expect(textarea).toHaveCSS("min-height", "100px");
    await expect(page.getByLabel("Compact multiple lines")).toHaveCSS(
      "min-height",
      "80px",
    );
    const appearance = (el: Element) => {
      const style = getComputedStyle(el);
      return {
        border: style.borderColor,
        background: style.backgroundColor,
        radius: style.borderRadius,
        weight: style.fontWeight,
      };
    };
    await expect
      .poll(() => textarea.evaluate(appearance))
      .toEqual(await input.evaluate(appearance));
    await input.fill("Editable");
    await textarea.fill("Editable\ntext");
    await input.focus();
    const focused = await input.evaluate(appearance);
    await textarea.focus();
    await expect.poll(() => textarea.evaluate(appearance)).toEqual(focused);
    for (const label of ["Disabled input", "Disabled textarea"]) {
      const disabled = page.getByLabel(label, { exact: true });
      await expect(disabled).toBeDisabled();
      expect(
        await disabled.evaluate((el) => Number(getComputedStyle(el).opacity)),
      ).toBeLessThan(1);
      const beforeHover = await disabled.evaluate(appearance);
      await disabled.hover({ force: true });
      expect(await disabled.evaluate(appearance)).toEqual(beforeHover);
    }
  }
});

test("alerts and playback use the active semantic palette", async ({
  page,
}) => {
  for (const theme of ["light", "dark"] as const) {
    await setTheme(page, theme);
    for (const [notice, token] of [
      ["Error notice", "--color-error"],
      ["Warning notice", "--color-warning"],
    ]) {
      const expected = await page.evaluate((name) => {
        const probe = document.createElement("span");
        probe.style.color = `var(${name})`;
        document.body.append(probe);
        const color = getComputedStyle(probe).color;
        probe.remove();
        return color;
      }, token);
      await expect(page.getByText(notice, { exact: true })).toHaveCSS(
        "color",
        expected,
      );
    }
    await page.locator("main").evaluate((el) => {
      (el as HTMLElement).style.setProperty("--workspace-accent", "#123456");
    });
    await expect(page.getByRole("slider")).toHaveCSS(
      "background-image",
      /rgb\(18, 52, 86\)/,
    );
  }
});

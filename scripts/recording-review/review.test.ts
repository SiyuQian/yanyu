import { describe, test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  rm,
  stat,
  unlink,
  chmod,
  symlink,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { Sample, Feedback } from "./server";
type ReviewSample = Sample & { feedback: Feedback | null };
async function listed(url: string): Promise<ReviewSample[]> {
  return (await (await fetch(url + "/api/samples")).json()) as ReviewSample[];
}
import { chromium } from "@playwright/test";
import { createReviewServer, snapshot, validateFeedback } from "./server";

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "recording-review-test-"));
  const sources = ["Yanyu", "Handy"].map((name) => ({
    name,
    directory: join(root, name),
  }));
  const wav = Buffer.alloc(16044);
  wav.write("RIFF");
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(8000, 24);
  wav.writeUInt32LE(16000, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(16000, 40);
  for (const source of sources) {
    await mkdir(join(source.directory, "recordings"), { recursive: true });
    await writeFile(join(source.directory, "recordings", "same.wav"), wav);
    const db = new Database(join(source.directory, "history.db"));
    db.run(
      "CREATE TABLE transcription_history (id INTEGER PRIMARY KEY, file_name TEXT, transcription_text TEXT, post_processed_text TEXT)",
    );
    db.run("INSERT INTO transcription_history VALUES (1, ?, ?, ?)", [
      "same.wav",
      "<img src=x onerror=alert(1)>",
      "Fictional polished text",
    ]);
    db.close();
  }
  await writeFile(join(sources[0].directory, "recordings", "orphan.wav"), wav);
  return { root, sources, data: join(root, "private"), wav };
}
const feedback = {
  judgment: "uncertain",
  reference: "Fictional reference",
  preferred: "",
  notes: "Synthetic note",
};

describe("private recording review", () => {
  test("snapshots duplicates and orphans without changing originals, appends and preserves prior samples", async () => {
    const f = await fixture();
    try {
      const dbPath = join(f.sources[0].directory, "history.db");
      const before = await readFile(dbPath);
      const samples = await snapshot(f.sources, f.data);
      expect(samples).toHaveLength(3);
      expect(samples.filter((s) => s.fileName === "same.wav")).toHaveLength(2);
      expect(
        samples.find((s) => s.fileName === "orphan.wav")?.transcription,
      ).toBeNull();
      expect(await readFile(dbPath)).toEqual(before);
      expect((await stat(f.data)).mode & 0o777).toBe(0o700);
      await unlink(join(f.sources[0].directory, "recordings", "orphan.wav"));
      await writeFile(
        join(f.sources[1].directory, "recordings", "new.wav"),
        f.wav,
      );
      const again = await snapshot(f.sources, f.data);
      expect(again).toHaveLength(4);
      expect(
        await readFile(join(f.data, "audio", samples[0].id + ".wav")),
      ).toEqual(f.wav);
    } finally {
      await rm(f.root, { recursive: true, force: true });
    }
  });
  test("refuses repository storage, symlinked storage and concurrent servers", async () => {
    const f = await fixture();
    try {
      for (const data of [
        resolve(import.meta.dir),
        join(f.sources[0].directory, "review"),
      ]) {
        let failed = false;
        try {
          await snapshot(f.sources, data);
        } catch {
          failed = true;
        }
        expect(failed).toBe(true);
      }
      await symlink(f.sources[0].directory, join(f.root, "alias"));
      let failed = false;
      try {
        await snapshot(f.sources, join(f.root, "alias"));
      } catch {
        failed = true;
      }
      expect(failed).toBe(true);
      const server = await createReviewServer({
        sources: f.sources,
        dataDirectory: f.data,
        port: 0,
      });
      try {
        failed = false;
        try {
          await createReviewServer({
            sources: f.sources,
            dataDirectory: f.data,
            port: 0,
          });
        } catch {
          failed = true;
        }
        expect(failed).toBe(true);
        expect(await listed(server.url)).toHaveLength(3);
      } finally {
        server.stop(true);
      }
    } finally {
      await rm(f.root, { recursive: true, force: true });
    }
  });
  test("refuses malformed stored data instead of overwriting it", async () => {
    const f = await fixture();
    try {
      await snapshot(f.sources, f.data);
      await writeFile(join(f.data, "feedback.json"), "{broken");
      let failed = false;
      try {
        await createReviewServer({
          sources: f.sources,
          dataDirectory: f.data,
          port: 0,
        });
      } catch {
        failed = true;
      }
      expect(failed).toBe(true);
      expect(await readFile(join(f.data, "feedback.json"), "utf8")).toBe(
        "{broken",
      );
      await rm(join(f.data, "feedback.json"));
      await writeFile(
        join(f.data, "samples.json"),
        JSON.stringify([
          { id: "a".repeat(64), extension: ".wav", transcription: 2 },
        ]),
      );
      failed = false;
      try {
        await snapshot(f.sources, f.data);
      } catch {
        failed = true;
      }
      expect(failed).toBe(true);
    } finally {
      await rm(f.root, { recursive: true, force: true });
    }
  });
  test("validates feedback without accepting arbitrary fields or invalid judgments", () => {
    expect(validateFeedback(feedback)).toEqual(feedback);
    for (const value of [
      null,
      { ...feedback, judgment: "yes" },
      { ...feedback, judgment: ["confirmed"] },
      { ...feedback, reference: 2 },
      { ...feedback, path: "/tmp/evil" },
      { ...feedback, notes: "a".repeat(20001) },
    ]) {
      expect(() => validateFeedback(value)).toThrow();
    }
  });
  test("HTTP guards paths and foreign hosts/origins, saves durably and reports write failures", async () => {
    const f = await fixture();
    let server = await createReviewServer({
      sources: f.sources,
      dataDirectory: f.data,
      port: 0,
    });
    try {
      const url = server.url;
      const samples = await listed(url);
      expect(samples).toHaveLength(3);
      expect(
        await (await fetch(url + "/audio/" + samples[0].id)).arrayBuffer(),
      ).toEqual(
        f.wav.buffer.slice(
          f.wav.byteOffset,
          f.wav.byteOffset + f.wav.byteLength,
        ),
      );
      expect(
        (
          await fetch(url + "/api/samples", {
            headers: { Origin: "https://evil.example" },
          })
        ).status,
      ).toBe(403);
      expect(
        (
          await fetch(url + "/api/samples", {
            headers: { Host: "evil.example" },
          })
        ).status,
      ).toBe(403);
      expect((await fetch(url + "/audio/%2e%2e%2fhistory.db")).status).toBe(
        404,
      );
      expect(
        (
          await fetch(url + "/api/feedback/unknown", {
            method: "PUT",
            body: JSON.stringify(feedback),
          })
        ).status,
      ).toBe(404);
      const save = () =>
        fetch(server.url + "/api/feedback/" + samples[0].id, {
          method: "PUT",
          headers: { Origin: server.url, "Content-Type": "application/json" },
          body: JSON.stringify(feedback),
        });
      expect((await save()).status).toBe(200);
      expect(
        (
          await fetch(url + "/api/feedback/" + samples[0].id, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ ...feedback, judgment: "invalid" }),
          })
        ).status,
      ).toBe(400);
      expect(
        (
          await fetch(url + "/api/feedback/" + samples[0].id, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: "x".repeat(250001),
          })
        ).status,
      ).toBe(413);
      expect(
        (
          await fetch(url + "/api/samples", {
            headers: { "Sec-Fetch-Site": "cross-site" },
          })
        ).status,
      ).toBe(403);
      const range = await fetch(url + "/audio/" + samples[0].id, {
        headers: { Range: "bytes=0-43" },
      });
      expect(range.status).toBe(206);
      expect((await range.arrayBuffer()).byteLength).toBe(44);
      server.stop(true);
      server = await createReviewServer({
        sources: f.sources,
        dataDirectory: f.data,
        port: 0,
      });
      const restored = await listed(server.url);
      expect(restored[0].feedback).toEqual(feedback);
      await rm(join(f.data, "feedback.json"));
      await mkdir(join(f.data, "feedback.json"));
      expect((await save()).status).toBe(500);
      expect((await listed(server.url))[0].feedback).toEqual(feedback);
    } finally {
      server.stop(true);
      await rm(f.root, { recursive: true, force: true });
    }
  });
  test("browser plays audio, uses safe text, protects edits and restores saved feedback after restart", async () => {
    const f = await fixture();
    let server = await createReviewServer({
      sources: f.sources,
      dataDirectory: f.data,
      port: 0,
    });
    const browser = await chromium.launch();
    try {
      const page = await browser.newPage();
      const remote: string[] = [];
      page.on("request", (request) => {
        if (!request.url().startsWith(server.url)) remote.push(request.url());
      });
      await page.goto(server.url);
      await page.getByLabel("参考转写").fill("Browser fictional reference");
      await page.getByLabel("判断").selectOption("confirmed");
      page.once("dialog", (dialog) => dialog.dismiss());
      await page.getByRole("button", { name: "下一条", exact: true }).click();
      expect(await page.getByLabel("参考转写").inputValue()).toBe(
        "Browser fictional reference",
      );
      await page.getByRole("button", { name: "保存", exact: true }).click();
      await page.getByText("已保存到本地").waitFor();
      await page.reload();
      expect(await page.getByLabel("参考转写").inputValue()).toBe(
        "Browser fictional reference",
      );
      expect(
        await page
          .locator("audio")
          .evaluate(async (audio: HTMLAudioElement) => {
            await audio.play();
            return audio.currentSrc.length > 0;
          }),
      ).toBe(true);
      await page.getByText("1 / 3 已审阅", { exact: true }).waitFor();
      const screenshot = join(tmpdir(), "yanyu-recording-review-fictional.png");
      await page.screenshot({ path: screenshot, fullPage: true });
      await chmod(screenshot, 0o600);
      await page.getByRole("button", { name: "下一条", exact: true }).focus();
      await page.keyboard.press("Enter");
      expect(await page.getByLabel("参考转写").inputValue()).toBe("");
      expect(await page.locator("#original").textContent()).toBe(
        "<img src=x onerror=alert(1)>",
      );
      expect(await page.locator("#original img").count()).toBe(0);
      await page.getByLabel("备注").fill("Discard me");
      page.once("dialog", (dialog) => dialog.accept());
      await page.getByRole("button", { name: "上一条", exact: true }).click();
      expect(await page.getByLabel("参考转写").inputValue()).toBe(
        "Browser fictional reference",
      );
      server.stop(true);
      server = await createReviewServer({
        sources: f.sources,
        dataDirectory: f.data,
        port: 0,
      });
      await page.goto(server.url);
      expect(await page.getByLabel("参考转写").inputValue()).toBe(
        "Browser fictional reference",
      );
      await rm(join(f.data, "feedback.json"));
      await mkdir(join(f.data, "feedback.json"));
      await page.getByLabel("备注").fill("Should remain unsaved");
      await page.getByRole("button", { name: "保存", exact: true }).click();
      await page.getByText("保存失败，修改仍未保存").waitFor();
      expect(await page.getByLabel("备注").inputValue()).toBe(
        "Should remain unsaved",
      );
      expect(remote).toEqual([]);
      await page.getByRole("button", { name: "保存", exact: true }).focus();
      expect(
        await page
          .getByRole("button", { name: "保存", exact: true })
          .evaluate((el) => el === document.activeElement),
      ).toBe(true);
    } finally {
      await browser.close();
      server.stop(true);
      await rm(f.root, { recursive: true, force: true });
    }
  }, 30000);
});

import { Database } from "bun:sqlite";
import { z } from "zod";
import { createHash, randomUUID } from "node:crypto";
import {
  mkdir,
  chmod,
  readdir,
  readFile,
  writeFile,
  rename,
  realpath,
  lstat,
  open,
  rm,
} from "node:fs/promises";
import { openSync, closeSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, relative, sep, extname } from "node:path";

export interface Source {
  name: string;
  directory: string;
}
export interface Feedback {
  judgment: "unreviewed" | "confirmed" | "rejected" | "uncertain";
  reference: string;
  preferred: string;
  notes: string;
}
export interface Sample {
  id: string;
  source: string;
  fileName: string;
  extension: string;
  transcription: string | null;
  processed: string | null;
}
interface History {
  file_name: string;
  transcription_text: string;
  post_processed_text: string | null;
}
const extensions = new Set([
  ".wav",
  ".mp3",
  ".ogg",
  ".m4a",
  ".flac",
  ".webm",
  ".aac",
]);
const repository = resolve(import.meta.dir, "../..");
function inside(path: string, parent: string) {
  return path === parent || path.startsWith(parent + sep);
}
async function canonicalPath(path: string) {
  const target = resolve(path);
  let ancestor = target;
  for (;;) {
    try {
      return resolve(await realpath(ancestor), relative(ancestor, target));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      ancestor = resolve(ancestor, "..");
    }
  }
}
async function privateDirectory(path: string) {
  const target = resolve(path);
  if (
    inside(target, repository) ||
    inside(await canonicalPath(target), repository)
  )
    throw new Error("Private data must stay outside the repository");
  await mkdir(target, { recursive: true, mode: 0o700 });
  if ((await lstat(target)).isSymbolicLink())
    throw new Error("Private directory must not be a symbolic link");
  await chmod(target, 0o700);
}
async function atomicJson(path: string, value: unknown) {
  const temporary = path + "." + randomUUID() + ".tmp";
  const file = await open(temporary, "wx", 0o600);
  try {
    try {
      await file.writeFile(JSON.stringify(value));
      await file.sync();
    } finally {
      await file.close();
    }
    await rename(temporary, path);
  } finally {
    await rm(temporary, { force: true });
  }
}
async function loadJson(path: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}
const feedbackSchema = z
  .object({
    judgment: z.enum(["unreviewed", "confirmed", "rejected", "uncertain"]),
    reference: z.string().max(20000),
    preferred: z.string().max(20000),
    notes: z.string().max(20000),
  })
  .strict();
export function validateFeedback(value: unknown): Feedback {
  return feedbackSchema.parse(value);
}
async function assertSeparate(sources: Source[], dataDirectory: string) {
  const target = await canonicalPath(dataDirectory);
  for (const source of sources) {
    if (
      inside(resolve(dataDirectory), resolve(source.directory)) ||
      inside(target, await canonicalPath(source.directory))
    )
      throw new Error("Snapshot must be separate from source data");
  }
}
const manifestSchema = z
  .array(
    z
      .object({
        id: z.string().regex(/^[a-f0-9]{64}$/),
        source: z.string(),
        fileName: z.string(),
        extension: z.string().refine((value) => extensions.has(value)),
        transcription: z.string().nullable(),
        processed: z.string().nullable(),
      })
      .strict(),
  )
  .refine(
    (samples) =>
      new Set(samples.map((sample) => sample.id)).size === samples.length,
  );
export async function snapshot(
  sources: Source[],
  dataDirectory: string,
): Promise<Sample[]> {
  await assertSeparate(sources, dataDirectory);
  await privateDirectory(dataDirectory);
  const audioDirectory = join(dataDirectory, "audio");
  await privateDirectory(audioDirectory);
  const manifest = await loadJson(join(dataDirectory, "samples.json"));
  const samples: Sample[] = manifestSchema.parse(manifest ?? []);
  const known = new Set(samples.map((sample) => sample.id));
  for (const source of sources) {
    let files;
    try {
      files = await readdir(join(source.directory, "recordings"), {
        withFileTypes: true,
      });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    let history: History[] = [];
    const databasePath = join(source.directory, "history.db");
    try {
      await lstat(databasePath);
      const database = new Database(databasePath, { readonly: true });
      try {
        const columns = database
          .query("PRAGMA table_info(transcription_history)")
          .all() as { name: string }[];
        const processed = columns.some(
          (column) => column.name === "post_processed_text",
        )
          ? "post_processed_text"
          : "NULL AS post_processed_text";
        history = database
          .query(
            `SELECT file_name, transcription_text, ${processed} FROM transcription_history ORDER BY id`,
          )
          .all() as History[];
      } finally {
        database.close();
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    for (const file of files.sort((a, b) => a.name.localeCompare(b.name))) {
      const extension = extname(file.name).toLowerCase();
      if (!file.isFile() || !extensions.has(extension)) continue;
      const bytes = await readFile(
        join(source.directory, "recordings", file.name),
      );
      const id = createHash("sha256")
        .update(resolve(source.directory))
        .update("\0")
        .update(file.name)
        .update("\0")
        .update(bytes)
        .digest("hex");
      if (known.has(id)) continue;
      const matching = history
        .filter((entry) => entry.file_name === file.name)
        .at(-1);
      await writeFile(join(audioDirectory, id + extension), bytes, {
        mode: 0o600,
      });
      samples.push({
        id,
        source: source.name,
        fileName: file.name,
        extension,
        transcription: matching?.transcription_text ?? null,
        processed: matching?.post_processed_text ?? null,
      });
      known.add(id);
    }
  }
  await atomicJson(join(dataDirectory, "samples.json"), samples);
  return samples;
}
export async function createReviewServer(options: {
  sources: Source[];
  dataDirectory: string;
  port?: number;
}) {
  await assertSeparate(options.sources, options.dataDirectory);
  await privateDirectory(options.dataDirectory);
  const lockPath = join(options.dataDirectory, "server.lock");
  let lock: number;
  try {
    lock = openSync(lockPath, "wx", 0o600);
  } catch {
    throw new Error(
      "Snapshot already in use. Stop the other server or remove server.lock after confirming it is stopped.",
    );
  }
  const release = () => {
    closeSync(lock);
    unlinkSync(lockPath);
  };
  try {
    const samples = await snapshot(options.sources, options.dataDirectory);
    const stored = await loadJson(join(options.dataDirectory, "feedback.json"));
    if (
      stored !== undefined &&
      (!stored || typeof stored !== "object" || Array.isArray(stored))
    )
      throw new Error("Invalid stored feedback");
    let feedback: Record<string, Feedback> = {};
    for (const [id, value] of Object.entries(stored ?? {})) {
      if (!samples.some((sample) => sample.id === id))
        throw new Error("Unknown stored sample");
      feedback[id] = validateFeedback(value);
    }
    const bundle = await Bun.build({
      entrypoints: [join(import.meta.dir, "ui.ts")],
      target: "browser",
      write: false,
    });
    if (!bundle.success) throw new Error("UI build failed");
    const javascript = await bundle.outputs[0].text();
    const html = await readFile(join(import.meta.dir, "index.html"), "utf8");
    let saves = Promise.resolve();
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: options.port ?? 17843,
      async fetch(request: Request) {
        const url = new URL(request.url);
        const origin = `http://127.0.0.1:${server.port}`;
        const headers = {
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
          "Referrer-Policy": "no-referrer",
          "Content-Security-Policy":
            "default-src 'none'; script-src 'self'; style-src 'self'; media-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        };
        const response = (
          body: string,
          status = 200,
          type = "application/json",
        ) =>
          new Response(body, {
            status,
            headers: { ...headers, "Content-Type": type },
          });
        if (
          request.headers.get("host") !== new URL(origin).host ||
          (request.headers.has("origin") &&
            request.headers.get("origin") !== origin) ||
          ["cross-site", "same-site"].includes(
            request.headers.get("sec-fetch-site") ?? "",
          )
        )
          return response("{}", 403);
        if (request.method === "GET") {
          if (url.pathname === "/")
            return response(html, 200, "text/html; charset=utf-8");
          if (url.pathname === "/ui.js")
            return response(javascript, 200, "text/javascript; charset=utf-8");
          if (url.pathname === "/style.css")
            return response(
              await readFile(join(import.meta.dir, "style.css"), "utf8"),
              200,
              "text/css",
            );
          if (url.pathname === "/api/samples")
            return response(
              JSON.stringify(
                samples.map((sample) => ({
                  ...sample,
                  feedback: feedback[sample.id] ?? null,
                })),
              ),
            );
          if (url.pathname.startsWith("/audio/")) {
            const sample = samples.find(
              (entry) => entry.id === url.pathname.slice("/audio/".length),
            );
            if (!sample) return response("{}", 404);
            return new Response(
              Bun.file(
                join(
                  options.dataDirectory,
                  "audio",
                  sample.id + sample.extension,
                ),
              ),
              { headers },
            );
          }
        }
        if (
          request.method === "PUT" &&
          url.pathname.startsWith("/api/feedback/")
        ) {
          const id = url.pathname.slice("/api/feedback/".length);
          if (!samples.some((sample) => sample.id === id))
            return response("{}", 404);
          if (request.headers.get("content-type") !== "application/json")
            return response("{}", 415);
          let value: Feedback;
          try {
            // Stream limits also cover clients that omit Content-Length.
            const reader = request.body?.getReader();
            if (!reader) return response("{}", 400);
            let size = 0;
            const chunks: Uint8Array[] = [];
            for (;;) {
              const next = await reader.read();
              if (next.done) break;
              size += next.value.length;
              if (size > 250000) {
                await reader.cancel();
                return response("{}", 413);
              }
              chunks.push(next.value);
            }
            value = validateFeedback(
              JSON.parse(Buffer.concat(chunks).toString("utf8")),
            );
          } catch {
            return response("{}", 400);
          }
          const operation = saves.then(async () => {
            const updated = { ...feedback, [id]: value };
            await atomicJson(
              join(options.dataDirectory, "feedback.json"),
              updated,
            );
            feedback = updated;
          });
          saves = operation.catch(() => {});
          try {
            await operation;
            return response("{}");
          } catch {
            return response("{}", 500);
          }
        }
        return response("{}", 404);
      },
      error() {
        return new Response("{}", { status: 500 });
      },
    });
    return {
      url: `http://127.0.0.1:${server.port}`,
      stop(force = false) {
        server.stop(force);
        release();
      },
    };
  } catch (error) {
    release();
    throw error;
  }
}

if (import.meta.main) {
  const appData =
    process.platform === "darwin"
      ? join(homedir(), "Library", "Application Support")
      : process.platform === "win32"
        ? (process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"))
        : (process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"));
  try {
    const server = await createReviewServer({
      sources: [
        { name: "Yanyu", directory: join(appData, "com.siyuqian.yanyu") },
        { name: "Handy", directory: join(appData, "com.pais.handy") },
      ],
      dataDirectory: join(appData, "com.siyuqian.yanyu-recording-review"),
    });
    console.log(`Recording review: ${server.url}`);
    for (const signal of ["SIGINT", "SIGTERM"] as const)
      process.once(signal, () => {
        server.stop(true);
        process.exit(0);
      });
  } catch {
    console.error(
      "Recording review could not start. Check source access, private snapshot directory, server.lock and port 17843.",
    );
    process.exitCode = 1;
  }
}

import { afterEach, beforeEach, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const script = resolve(import.meta.dirname, "release-version.ts");
let fixture: string;
const initialFiles = {
  "package.json": '{"name":"yanyu-app","version":"0.0.1"}\n',
  "src-tauri/tauri.conf.json": '{"productName":"Yanyu","version":"0.0.1"}\n',
  "src-tauri/Cargo.toml": `# Keep manifest comments.
[package]
name = "yanyu"
version = "0.0.1" # App version

[dependencies]
other = "0.0.1"
`,
  "src-tauri/Cargo.lock": `# Keep dependency versions untouched.
version = 4

[[package]]
name = "other"
version = "0.0.1"

[[package]]
name = "yanyu"
version = "0.0.1"
dependencies = ["other"]

[[package]]
name = "yanyu-core"
version = "0.1.0"
`,
};

beforeEach(() => {
  fixture = mkdtempSync(join(tmpdir(), "yanyu-version-"));
  mkdirSync(join(fixture, "src-tauri"));
  for (const [path, content] of Object.entries(initialFiles)) {
    writeFileSync(join(fixture, path), content);
  }
});

afterEach(() => rmSync(fixture, { recursive: true, force: true }));

function run(...args: string[]) {
  return Bun.spawnSync([process.execPath, script, ...args], {
    cwd: fixture,
    stdout: "pipe",
    stderr: "pipe",
  });
}

function read(path: string) {
  return readFileSync(join(fixture, path), "utf8");
}

function expectUnchanged() {
  for (const [path, content] of Object.entries(initialFiles)) {
    expect(read(path)).toBe(content);
  }
}

test("setting a version synchronizes desktop metadata without changing dependencies", () => {
  expect(run("set", "0.2.0").exitCode).toBe(0);
  expect(JSON.parse(read("package.json")).version).toBe("0.2.0");
  expect(JSON.parse(read("src-tauri/tauri.conf.json")).version).toBe("0.2.0");
  expect(read("src-tauri/Cargo.toml")).toBe(
    initialFiles["src-tauri/Cargo.toml"].replace(
      'version = "0.0.1"',
      'version = "0.2.0"',
    ),
  );
  const lock = Bun.TOML.parse(read("src-tauri/Cargo.lock"));
  expect(lock.package).toEqual([
    { name: "other", version: "0.0.1" },
    { name: "yanyu", version: "0.2.0", dependencies: ["other"] },
    { name: "yanyu-core", version: "0.1.0" },
  ]);
  expect(run("check", "v0.2.0").exitCode).toBe(0);
});

test("prerelease versions round-trip and match their exact tag", () => {
  expect(run("set", "0.2.0-1").exitCode).toBe(0);
  expect(run("check", "v0.2.0-1").exitCode).toBe(0);
  expect(run("check", "v0.2.0").exitCode).toBe(1);
});

test("the largest native installer version round-trips", () => {
  expect(run("set", "255.255.65535-65535").exitCode).toBe(0);
  expect(run("check", "v255.255.65535-65535").exitCode).toBe(0);
});

test.each([
  "v0.2.0",
  "0.2",
  "01.2.0",
  "0.2.0+build.1",
  "0.2.0-01",
  "0.2.0-",
  "0.2.0\n",
  "0.2.0-rc.1",
  "0.2.0-alpha",
  "256.0.0",
  "0.256.0",
  "0.0.65536",
  "0.2.0-65536",
])("invalid version %j fails before modifying files", (version) => {
  expect(run("set", version).exitCode).toBe(1);
  expectUnchanged();
});

test.each(Object.keys(initialFiles))(
  "the checker detects version drift in %s without repairing it",
  (path) => {
    const content = read(path).replaceAll("0.0.1", "0.0.2");
    writeFileSync(join(fixture, path), content);
    const result = run("check");
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("Version mismatch");
    expect(read(path)).toBe(content);
  },
);

test("consistent versions pass without writing or requiring a tag", () => {
  expect(run("check").exitCode).toBe(0);
  expectUnchanged();
});

test.each(["v0.0.2", "0.0.1", "refs/tags/v0.0.1", "v0.0.1 "])(
  "the checker rejects a mismatching or noncanonical tag %j",
  (tag) => {
    expect(run("check", tag).exitCode).toBe(1);
    expectUnchanged();
  },
);

test("a missing app lock entry fails before any version files are written", () => {
  writeFileSync(
    join(fixture, "src-tauri/Cargo.lock"),
    initialFiles["src-tauri/Cargo.lock"].replace(
      'name = "yanyu"',
      'name = "renamed"',
    ),
  );
  expect(run("set", "0.2.0").exitCode).toBe(1);
  for (const path of [
    "package.json",
    "src-tauri/tauri.conf.json",
    "src-tauri/Cargo.toml",
  ] as const) {
    expect(read(path)).toBe(initialFiles[path]);
  }
});

test.each([
  { args: [] },
  { args: ["set"] },
  { args: ["patch"] },
  { args: ["check", "v0.0.1", "extra"] },
])("invalid CLI arguments fail without modifying files: $args", ({ args }) => {
  expect(run(...args).exitCode).toBe(1);
  expectUnchanged();
});

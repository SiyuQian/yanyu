import { afterEach, beforeEach, expect, test } from "bun:test";
import {
  existsSync,
  mkdtempSync,
  mkdirSync,
  cpSync,
  realpathSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
let fixture: string;

beforeEach(() => {
  fixture = realpathSync(mkdtempSync(join(tmpdir(), "yanyu-build-")));
  mkdirSync(join(fixture, "scripts"));
  const fastScript = join(root, "scripts/build-fast.ts");
  if (existsSync(fastScript))
    cpSync(fastScript, join(fixture, "scripts/build-fast.ts"));
  writeFileSync(
    join(fixture, "package.json"),
    JSON.stringify({ scripts: { tauri: "bun capture.ts" } }),
  );
  writeFileSync(
    join(fixture, "capture.ts"),
    `
    console.log(JSON.stringify({ args: process.argv.slice(2), env: {
      target: process.env.CARGO_TARGET_DIR,
      lto: process.env.CARGO_PROFILE_RELEASE_LTO,
      units: process.env.CARGO_PROFILE_RELEASE_CODEGEN_UNITS,
      incremental: process.env.CARGO_PROFILE_RELEASE_INCREMENTAL,
      cargoIncremental: process.env.CARGO_INCREMENTAL,
    }}));
    process.exit(Number(process.env.BUILD_TEST_EXIT_CODE || 0));
  `,
  );
});

afterEach(() => rmSync(fixture, { recursive: true, force: true }));

function run(command: string[], env: Record<string, string> = {}) {
  return Bun.spawnSync(command, {
    cwd: fixture,
    env: {
      ...process.env,
      PATH: `${dirname(process.execPath)}${delimiter}${process.env.PATH}`,
      ...env,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
}

test("fast builds isolate their cache and override inherited release settings", () => {
  const result = run(
    [process.execPath, "scripts/build-fast.ts", "--no-bundle"],
    {
      CARGO_TARGET_DIR: "/normal-build-cache",
      CARGO_PROFILE_RELEASE_LTO: "true",
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS: "1",
      CARGO_INCREMENTAL: "0",
    },
  );
  expect(result.exitCode).toBe(0);
  const output = JSON.parse(result.stdout.toString().trim());
  expect(output.env).toEqual({
    target: join(fixture, "src-tauri/target/fast"),
    lto: "off",
    units: "16",
    incremental: "true",
    cargoIncremental: "1",
  });
  expect(output.args[0]).toBe("build");
  expect(output.args.at(-1)).toBe("--no-bundle");
  if (process.platform === "darwin") {
    const config = output.args[output.args.indexOf("--config") + 1];
    expect(JSON.parse(config).bundle.targets).toEqual(["app"]);
  }
});

test("fast builds return the compiler failure status", () => {
  const result = run([process.execPath, "scripts/build-fast.ts"], {
    BUILD_TEST_EXIT_CODE: "23",
  });
  expect(result.exitCode).toBe(23);
});

const bundleScript = join(root, "scripts/ci/tauri-bundle.sh");

test("the Linux action bundles without compiling and preserves target and bundle arguments", () => {
  const args = [
    "--target",
    "x86_64-unknown-linux-gnu",
    "--bundles",
    "appimage,rpm",
    "--config",
    "config with spaces.json",
  ];
  const result = run(["bash", bundleScript, "build", ...args]);
  expect(result.exitCode).toBe(0);
  expect(JSON.parse(result.stdout.toString().trim()).args).toEqual([
    "bundle",
    ...args,
  ]);
});

test("the Linux action rejects commands that could start another compilation", () => {
  const result = run(["bash", bundleScript, "dev"]);
  expect(result.exitCode).toBe(1);
  expect(result.stdout.toString()).toBe("");
});

test("the Linux action returns bundling failures to CI", () => {
  const result = run(["bash", bundleScript, "build", "--debug"], {
    BUILD_TEST_EXIT_CODE: "23",
  });
  expect(result.exitCode).toBe(23);
});

test.each([
  { args: ["--bundles", "deb"], directory: "src-tauri/target/release" },
  {
    args: ["--target", "x86_64-unknown-linux-gnu", "--debug"],
    directory: "src-tauri/target/x86_64-unknown-linux-gnu/debug",
  },
  {
    args: ["-t", "aarch64-unknown-linux-gnu", "-d"],
    directory: "src-tauri/target/aarch64-unknown-linux-gnu/debug",
  },
  {
    args: ["--target=x86_64-unknown-linux-gnu"],
    directory: "src-tauri/target/x86_64-unknown-linux-gnu/release",
  },
])(
  "Linux compilation publishes the matching artifact directory: $directory",
  ({ args, directory }) => {
    const outputFile = join(fixture, "github-output");
    const result = run(
      ["bash", join(root, "scripts/ci/build-linux.sh"), ...args],
      { GITHUB_OUTPUT: outputFile },
    );
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(result.stdout.toString().trim()).args).toEqual([
      "build",
      "--no-bundle",
      ...args,
    ]);
    expect(readFileSync(outputFile, "utf8")).toBe(`directory=${directory}\n`);
  },
);

import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const bundleArgs =
  process.platform === "darwin"
    ? ["--config", JSON.stringify({ bundle: { targets: ["app"] } })]
    : [];

const result = Bun.spawnSync(
  [
    process.execPath,
    "run",
    "tauri",
    "build",
    ...bundleArgs,
    ...process.argv.slice(2),
  ],
  {
    cwd: root,
    env: {
      ...process.env,
      // Keep these artifacts separate from fully optimized release builds.
      CARGO_TARGET_DIR: resolve(root, "src-tauri/target/fast"),
      CARGO_PROFILE_RELEASE_LTO: "off",
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS: "16",
      CARGO_PROFILE_RELEASE_INCREMENTAL: "true",
      CARGO_INCREMENTAL: "1",
    },
    stdio: ["inherit", "inherit", "inherit"],
  },
);

process.exit(result.exitCode);

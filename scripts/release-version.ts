import { readFileSync, writeFileSync } from "node:fs";

// Every release includes MSI, whose version fields and prerelease must be numeric.
function validateVersion(version: string): void {
  const match =
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(0|[1-9]\d*))?$/.exec(
      version,
    );
  const limits = [255, 255, 65535, 65535];
  if (
    !match ||
    match[0] !== version ||
    match.slice(1).some((component, index) => Number(component) > limits[index])
  ) {
    throw new Error(
      `Invalid version ${JSON.stringify(version)}: use major.minor.patch or major.minor.patch-N without leading zeros; MSI limits major/minor to 255 and patch/N to 65535 (for example 0.2.0 or 0.2.0-1)`,
    );
  }
}

function replaceTomlVersion(section: string, version: string): string {
  const pattern = /^(version\s*=\s*)"[^"]*"/gm;
  if ([...section.matchAll(pattern)].length !== 1) {
    throw new Error("Expected exactly one version in the app's TOML section");
  }
  return section.replace(pattern, `$1"${version}"`);
}

function run(): void {
  const [command, value, ...extra] = process.argv.slice(2);
  if (
    extra.length ||
    (command !== "set" && command !== "check") ||
    (command === "set" && !value)
  ) {
    throw new Error(
      "Usage: bun run version:set <version> | bun run check:version [v<version>]",
    );
  }
  if (command === "set") validateVersion(value);

  const packagePath = "package.json";
  const tauriPath = "src-tauri/tauri.conf.json";
  const manifestPath = "src-tauri/Cargo.toml";
  const lockPath = "src-tauri/Cargo.lock";
  const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
  const tauriJson = JSON.parse(readFileSync(tauriPath, "utf8"));
  const manifestText = readFileSync(manifestPath, "utf8");
  const manifest = Bun.TOML.parse(manifestText) as {
    package: { name: string; version: string };
  };
  const lockText = readFileSync(lockPath, "utf8");
  const lockSections = lockText.split(/(?=^\[\[package\]\])/m);
  const appSections = lockSections.filter((section) => {
    return Bun.TOML.parse(section).package?.some(
      (entry: { name: string }) => entry.name === manifest.package.name,
    );
  });
  if (appSections.length !== 1) {
    throw new Error(
      `Expected exactly one ${manifest.package.name} package in ${lockPath}`,
    );
  }
  const appLock = Bun.TOML.parse(appSections[0]).package[0] as {
    version: string;
  };

  if (command === "check") {
    const versions = {
      [packagePath]: packageJson.version,
      [tauriPath]: tauriJson.version,
      [manifestPath]: manifest.package.version,
      [lockPath]: appLock.version,
    };
    for (const [path, version] of Object.entries(versions)) {
      if (version !== packageJson.version) {
        throw new Error(
          `Version mismatch: ${path} has ${version}, expected ${packageJson.version}`,
        );
      }
      validateVersion(version);
    }
    if (value !== undefined && value !== `v${packageJson.version}`) {
      throw new Error(
        `Release tag ${value} must match v${packageJson.version}`,
      );
    }
    console.log(
      `Desktop version ${packageJson.version} is consistent${value ? ` with ${value}` : ""}.`,
    );
    return;
  }

  // Prepare every replacement before writing so malformed inputs leave files intact.
  const nextManifest = manifestText
    .split(/(?=^\[)/m)
    .map((section) =>
      section.startsWith("[package]")
        ? replaceTomlVersion(section, value)
        : section,
    )
    .join("");
  const nextLock = lockSections
    .map((section) =>
      section === appSections[0] ? replaceTomlVersion(section, value) : section,
    )
    .join("");
  const updates = {
    [packagePath]: `${JSON.stringify({ ...packageJson, version: value }, null, 2)}\n`,
    [tauriPath]: `${JSON.stringify({ ...tauriJson, version: value }, null, 2)}\n`,
    [manifestPath]: nextManifest,
    [lockPath]: nextLock,
  };
  for (const [path, content] of Object.entries(updates)) {
    writeFileSync(path, content);
  }
  console.log(
    `Updated desktop version to ${value}. Commit the version files before tagging v${value}.`,
  );
}

try {
  run();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}

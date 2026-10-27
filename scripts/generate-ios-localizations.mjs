import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const outputDirectory = path.join(repositoryRoot, "ios", "Yanyu");
const microphoneDescriptionKey =
  "onboarding.permissions.microphone.description";

export function flattenTranslations(value, prefix = "") {
  if (typeof value === "string") {
    return prefix ? { [prefix]: value } : {};
  }
  if (Array.isArray(value) || typeof value !== "object" || value === null) {
    throw new TypeError(
      `Unsupported translation value at ${prefix || "<root>"}`,
    );
  }

  return Object.fromEntries(
    Object.entries(value)
      .flatMap(([key, nested]) =>
        Object.entries(
          flattenTranslations(nested, prefix ? `${prefix}.${key}` : key),
        ),
      )
      .sort(([left], [right]) => left.localeCompare(right)),
  );
}

export function escapePropertyListString(value) {
  return value
    .replaceAll("\\", "\\\\")
    .replaceAll('"', '\\"')
    .replaceAll("\n", "\\n")
    .replaceAll("\r", "\\r");
}

function loadTranslations(language) {
  const filePath = path.join(
    repositoryRoot,
    "src",
    "i18n",
    "locales",
    language,
    "translation.json",
  );
  return flattenTranslations(JSON.parse(readFileSync(filePath, "utf8")));
}

function makeCatalog(english, simplifiedChinese) {
  const strings = {};
  for (const key of Object.keys(english)) {
    const chineseValue = simplifiedChinese[key];
    if (chineseValue === undefined) {
      throw new Error(
        `Simplified Chinese is missing the iOS localization key: ${key}`,
      );
    }
    strings[key] = {
      localizations: {
        en: { stringUnit: { state: "translated", value: english[key] } },
        "zh-Hans": { stringUnit: { state: "translated", value: chineseValue } },
      },
    };
  }
  return `${JSON.stringify({ sourceLanguage: "en", strings, version: "1.0" }, null, 2)}\n`;
}

function makeInfoPlistStrings(translations) {
  const description = translations[microphoneDescriptionKey];
  if (description === undefined) {
    throw new Error(
      `Missing microphone purpose string: ${microphoneDescriptionKey}`,
    );
  }
  return `"NSMicrophoneUsageDescription" = "${escapePropertyListString(description)}";\n`;
}

function expectedOutputs() {
  const english = loadTranslations("en");
  const simplifiedChinese = loadTranslations("zh");
  return new Map([
    [
      path.join(outputDirectory, "Resources", "Localizable.xcstrings"),
      makeCatalog(english, simplifiedChinese),
    ],
    [
      path.join(outputDirectory, "en.lproj", "InfoPlist.strings"),
      makeInfoPlistStrings(english),
    ],
    [
      path.join(outputDirectory, "zh-Hans.lproj", "InfoPlist.strings"),
      makeInfoPlistStrings(simplifiedChinese),
    ],
  ]);
}

function run() {
  const checkOnly = process.argv.includes("--check");
  let stale = false;
  for (const [filePath, contents] of expectedOutputs()) {
    if (checkOnly) {
      let current;
      try {
        current = readFileSync(filePath, "utf8");
      } catch {
        current = undefined;
      }
      if (current !== contents) {
        console.error(
          `Generated iOS localization is stale: ${path.relative(repositoryRoot, filePath)}`,
        );
        stale = true;
      }
      continue;
    }
    mkdirSync(path.dirname(filePath), { recursive: true });
    writeFileSync(filePath, contents);
  }

  if (stale) {
    process.exitCode = 1;
  } else if (checkOnly) {
    console.log(
      "iOS localizations match the English and Simplified Chinese i18next sources.",
    );
  }
}

if (import.meta.main) {
  run();
}

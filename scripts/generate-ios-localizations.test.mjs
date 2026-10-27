import assert from "node:assert/strict";
import test from "node:test";
import {
  escapePropertyListString,
  flattenTranslations,
} from "./generate-ios-localizations.mjs";

test("flattens nested i18next keys without changing their names", () => {
  assert.deepEqual(
    flattenTranslations({
      common: { copy: "Copy" },
      overlay: { transcribing: "Transcribing…" },
    }),
    {
      "common.copy": "Copy",
      "overlay.transcribing": "Transcribing…",
    },
  );
});

test("escapes property-list strings", () => {
  assert.equal(
    escapePropertyListString('Say "hello"\\\nnext'),
    String.raw`Say \"hello\"\\\nnext`,
  );
});

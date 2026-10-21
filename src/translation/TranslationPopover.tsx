import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { useTranslation } from "react-i18next";
import { commands, type TranslationState } from "@/bindings";

export default function TranslationPopover() {
  const { t } = useTranslation();
  const [state, setState] = useState<TranslationState>({
    phase: "loading",
    text: null,
    error: null,
    revision: 0,
  });
  const [actionError, setActionError] = useState(false);
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    const apply = (next: TranslationState) => {
      if (active)
        setState((previous) =>
          next.revision >= previous.revision ? next : previous,
        );
    };
    void (async () => {
      // Listen before the snapshot so cold window startup cannot lose a result.
      unlisten = await listen<TranslationState>("translation-state", (event) =>
        apply(event.payload),
      );
      if (!active) {
        unlisten();
        return;
      }
      apply(await commands.getTranslationState());
    })().catch(() => {
      if (active)
        setState((previous) => ({
          ...previous,
          phase: "error",
          error: "unavailable",
        }));
    });
    return () => {
      active = false;
      unlisten?.();
    };
  }, []);
  useEffect(() => {
    setActionError(false);
    setCopied(false);
  }, [state.revision]);
  useEffect(() => {
    const close = (event: KeyboardEvent) => {
      if (event.key === "Escape") void commands.dismissTranslation();
    };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, []);
  const copy = async () => {
    setActionError(false);
    try {
      const result = await commands.copyTranslation(state.revision);
      if (result.status === "error") {
        setActionError(true);
        return;
      }
      setCopied(true);
    } catch {
      setActionError(true);
    }
  };
  return (
    <section
      className="h-screen flex flex-col gap-3 border border-mid-gray/30 rounded-xl bg-background p-4 text-text"
      aria-label={t("translation.title")}
    >
      <header className="flex items-center justify-between gap-3">
        <h1 className="font-semibold text-base">{t("translation.title")}</h1>
        <button
          type="button"
          className="rounded px-2 py-1 hover:bg-mid-gray/20"
          onClick={() => void commands.dismissTranslation()}
        >
          {t("translation.close")}
        </button>
      </header>
      <div className="flex-1 min-h-0 overflow-y-auto select-text">
        {state.phase === "loading" && (
          <p role="status">{t("translation.loading")}</p>
        )}
        {state.phase === "result" && (
          <p className="whitespace-pre-wrap break-words" lang="zh-CN">
            {state.text}
          </p>
        )}
        {state.phase === "error" && (
          <p role="alert">
            {t(`translation.errors.${state.error}`, {
              defaultValue: t("translation.errors.unavailable"),
            })}
          </p>
        )}
        {state.error === "missing_model" && (
          <button
            type="button"
            className="mt-3 underline"
            onClick={() => void commands.openTranslationModelSettings()}
          >
            {t("translation.openSettings")}
          </button>
        )}
        {actionError && (
          <p role="alert">{t("translation.errors.copy_failed")}</p>
        )}
      </div>
      <button
        type="button"
        disabled={state.phase !== "result" || !state.text}
        onClick={() => void copy()}
        className="rounded-lg bg-logo-primary/15 px-3 py-2 disabled:opacity-50"
      >
        {t(copied ? "translation.copied" : "translation.copy")}
      </button>
    </section>
  );
}

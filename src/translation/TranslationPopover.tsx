import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { useTranslation } from "react-i18next";
import {
  Check,
  Copy,
  Languages,
  LoaderCircle,
  Sparkles,
  X,
} from "lucide-react";
import { commands, type TranslationState } from "@/bindings";

export default function TranslationPopover() {
  const { t } = useTranslation();
  const [state, setState] = useState<TranslationState>({
    operation: "translate",
    phase: "loading",
    text: null,
    error: null,
    revision: 0,
  });
  const [actionError, setActionError] = useState(false);
  const [copied, setCopied] = useState(false);
  const polishing = state.operation === "polish";
  const namespace = polishing ? "polish" : "translation";
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
      className="flex h-screen flex-col overflow-hidden rounded-2xl border border-mid-gray/25 bg-background text-text shadow-2xl"
      aria-label={t(`${namespace}.title`)}
    >
      <header
        data-tauri-drag-region="deep"
        className="flex shrink-0 cursor-grab items-center gap-3 border-b border-mid-gray/15 px-5 py-4 active:cursor-grabbing"
      >
        <div className="flex min-w-0 flex-1 items-center gap-3">
          <span className="flex size-9 shrink-0 items-center justify-center rounded-xl bg-logo-primary/20 text-logo-stroke">
            {polishing ? (
              <Sparkles size={19} aria-hidden="true" />
            ) : (
              <Languages size={19} aria-hidden="true" />
            )}
          </span>
          <h1 className="truncate font-semibold text-base">
            {t(`${namespace}.title`)}
          </h1>
        </div>
        <button
          type="button"
          aria-label={t("translation.close")}
          className="icon-action text-text/65"
          onClick={() => void commands.dismissTranslation()}
        >
          <X size={18} aria-hidden="true" />
        </button>
      </header>
      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto px-5 py-4 select-text">
        {state.phase === "loading" && (
          <div
            className="flex flex-1 items-center justify-center gap-3 text-sm text-text/65"
            role="status"
          >
            <LoaderCircle
              className="animate-spin text-background-ui"
              size={18}
              aria-hidden="true"
            />
            <p>{t(`${namespace}.loading`)}</p>
          </div>
        )}
        {state.phase === "result" && (
          <div className="min-h-full rounded-xl border border-mid-gray/15 bg-mid-gray/5 p-4">
            <p
              className="whitespace-pre-wrap break-words text-[15px] leading-7"
              lang={polishing ? undefined : "zh-CN"}
            >
              {state.text}
            </p>
          </div>
        )}
        {state.phase === "error" && (
          <div
            className="rounded-xl border border-error/20 bg-error/5 p-4 text-sm leading-6"
            role="alert"
          >
            {t(`${namespace}.errors.${state.error}`, {
              defaultValue: t(`translation.errors.${state.error}`, {
                defaultValue: t(`${namespace}.errors.unavailable`),
              }),
            })}
          </div>
        )}
        {state.error === "missing_model" && (
          <button
            type="button"
            className="mt-3 self-start rounded-lg px-3 py-2 text-sm font-medium text-background-ui underline-offset-4 hover:bg-background-ui/10 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-logo-primary"
            onClick={() => void commands.openTranslationModelSettings()}
          >
            {t("translation.openSettings")}
          </button>
        )}
        {actionError && (
          <p className="mt-3 text-sm text-error" role="alert">
            {t(`${namespace}.errors.copy_failed`)}
          </p>
        )}
      </div>
      <footer className="shrink-0 border-t border-mid-gray/15 px-5 py-4">
        {polishing && (
          <p className="mb-3 text-xs text-text/60">{t("polish.reviewHint")}</p>
        )}
        <button
          type="button"
          disabled={state.phase !== "result" || !state.text}
          onClick={() => void copy()}
          className="flex w-full items-center justify-center gap-2 rounded-xl bg-background-ui px-4 py-3 font-semibold text-white shadow-sm transition hover:brightness-110 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-logo-primary disabled:cursor-not-allowed disabled:opacity-40"
        >
          {copied ? (
            <Check size={18} aria-hidden="true" />
          ) : (
            <Copy size={17} aria-hidden="true" />
          )}
          {t(copied ? "translation.copied" : `${namespace}.copy`)}
        </button>
      </footer>
    </section>
  );
}

import { useEffect, useRef, useState } from "react";
import { commands, type CorrectionSession } from "@/bindings";
import { listen } from "@tauri-apps/api/event";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/Button";
import { Textarea } from "@/components/ui/Textarea";

type Session = CorrectionSession;

export default function CorrectionPanel() {
  const { t } = useTranslation();
  const [session, setSession] = useState<Session | null>(null);
  const [selection, setSelection] = useState("");
  const [outcome, setOutcome] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const composing = useRef(false);
  const dirty = useRef(false);
  const current = useRef(session);
  current.current = session;

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const result = await commands.getCorrectionSession();
        if (result.status === "error") throw result.error;
        const next = result.data;
        if (
          active &&
          !dirty.current &&
          current.current?.generation !== next?.generation
        ) {
          setSession(next);
          setOutcome("");
          setError("");
          setSelection("");
        }
        if (active) document.getElementById("correction-draft")?.focus();
      } catch (e) {
        if (active) setError(String(e));
      }
    };
    const unlisten = listen("correction-open", load);
    void load();
    return () => {
      active = false;
      void unlisten.then((stop) => stop());
    };
  }, []);

  useEffect(() => {
    document.getElementById("correction-draft")?.focus();
  }, [session?.generation]);

  const close = async () => {
    try {
      if (session) {
        const saved = await commands.saveCorrectionDraft(
          session.generation,
          session.draft,
          session.word,
        );
        if (saved.status === "error" && saved.error !== "stale_session")
          throw saved.error;
      }
      const closed = await commands.closeCorrection();
      if (closed.status === "error") throw closed.error;
    } catch (e) {
      setError(String(e));
    }
  };
  const apply = async () => {
    if (!session || busy || composing.current) return;
    setBusy(true);
    setError("");
    try {
      const result = await commands.applyCorrection(
        session.generation,
        session.draft,
        session.word,
      );
      if (result.status === "error") throw result.error;
      setOutcome(result.data);
      setSession({ ...session, word: null });
      dirty.current = false;
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <main
      className="p-5 space-y-3 text-text bg-background min-h-screen"
      onKeyDown={(event) => {
        if (
          composing.current ||
          event.nativeEvent.isComposing ||
          event.keyCode === 229
        )
          return;
        if (event.key === "Escape") {
          event.preventDefault();
          void close();
        }
      }}
    >
      <h1 className="text-lg font-semibold">{t("correction.title")}</h1>
      <p className="text-sm text-text/60">{t("correction.hint")}</p>
      {session ? (
        <>
          <label className="block text-sm" htmlFor="correction-draft">
            {t("correction.text")}
          </label>
          <Textarea
            id="correction-draft"
            className="w-full"
            rows={4}
            value={session.draft}
            disabled={busy}
            onChange={(event) => {
              dirty.current = true;
              setSession({ ...session, draft: event.target.value, word: null });
              setSelection("");
              setOutcome("");
            }}
            onSelect={(event) => {
              const node = event.currentTarget;
              setSelection(
                node.value.slice(node.selectionStart, node.selectionEnd).trim(),
              );
            }}
            onCompositionStart={() => {
              composing.current = true;
            }}
            onCompositionEnd={() => {
              composing.current = false;
            }}
            onKeyDown={(event) => {
              if (
                event.key === "Enter" &&
                !event.shiftKey &&
                !composing.current &&
                !event.nativeEvent.isComposing &&
                event.keyCode !== 229
              ) {
                event.preventDefault();
                void apply();
              }
            }}
          />
          <div className="flex items-center gap-2">
            <Button
              variant="secondary"
              size="sm"
              disabled={busy || !selection || selection.length > 80}
              onClick={() => {
                dirty.current = true;
                setSession({ ...session, word: selection });
              }}
            >
              {t("correction.remember")}
            </Button>
            {session.word && (
              <span className="text-sm">
                {t("correction.selected", { word: session.word })}
              </span>
            )}
          </div>
          <div className="flex gap-2">
            <Button
              disabled={busy || !session.draft.trim()}
              onClick={() => void apply()}
            >
              {t("correction.apply")}
            </Button>
            <Button
              variant="secondary"
              disabled={busy}
              onClick={() => void close()}
            >
              {t("correction.close")}
            </Button>
          </div>
        </>
      ) : (
        <p>{t("correction.empty")}</p>
      )}
      <p role="status" className="text-sm">
        {outcome && t(`correction.outcomes.${outcome}`)}
      </p>
      {error === "stale_session" && (
        <Button
          variant="secondary"
          disabled={busy}
          onClick={async () => {
            try {
              const result = await commands.getCorrectionSession();
              if (result.status === "error") throw result.error;
              dirty.current = false;
              setSession(result.data);
              setError("");
              setOutcome("");
              setSelection("");
            } catch (e) {
              setError(String(e));
            }
          }}
        >
          {t("correction.loadLatest")}
        </Button>
      )}
      {error && (
        <p role="alert" className="text-sm text-red-500">
          {t(`correction.errors.${error}`, {
            defaultValue: t("correction.errors.generic"),
          })}
        </p>
      )}
    </main>
  );
}

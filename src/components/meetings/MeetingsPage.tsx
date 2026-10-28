import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { convertFileSrc } from "@tauri-apps/api/core";
import {
  commands,
  type Meeting,
  type MeetingControl,
  type MeetingMode,
  type MeetingSetup,
  type MeetingSummary,
  type Result,
} from "@/bindings";
import { Dialog } from "@/components/ui/Dialog";
import { Button } from "@/components/ui/Button";
import { Dropdown } from "@/components/ui/Dropdown";

const time = (ms: number) =>
  `${Math.floor(ms / 60000)
    .toString()
    .padStart(2, "0")}:${Math.floor((ms / 1000) % 60)
    .toString()
    .padStart(2, "0")}`;
const recording = (meeting: { status: string }) =>
  ["recording", "paused"].includes(meeting.status);
const processing = (meeting: { status: string }) =>
  ["transcribing", "summarizing"].includes(meeting.status);
function unwrap<T>(result: Result<T, string>): T {
  if (result.status === "error") throw result.error;
  return result.data;
}
export function MeetingsPage() {
  const { t } = useTranslation();
  const [rows, setRows] = useState<MeetingSummary[]>([]);
  const [offset, setOffset] = useState(0);
  const [hasMore, setHasMore] = useState(false);
  const [durabilityWarning, setDurabilityWarning] = useState<string>();
  const [activeRows, setActiveRows] = useState<MeetingSummary[]>([]);
  const [current, setCurrent] = useState<Meeting>();
  const [setup, setSetup] = useState<MeetingSetup>();
  const [selected, setSelected] = useState<string>();
  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  const [draft, setDraft] = useState<Meeting>();
  const [mode, setMode] = useState<MeetingMode>("in_person");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [dirty, setDirty] = useState(false);
  const dirtyRef = useRef(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [audio, setAudio] = useState<string>();
  const player = useRef<HTMLAudioElement>(null);
  const refresh = useCallback(async () => {
    const [list, availability] = await Promise.all([
      commands.meetingList(offset),
      commands.meetingSetup(),
    ]);
    const page = unwrap(list);
    const entries = page.items;
    setRows(entries);
    setHasMore(page.has_more);
    setActiveRows(page.active);
    setSetup(availability);
    setSelected((current) =>
      current && [...entries, ...page.active].some((row) => row.id === current)
        ? current
        : (entries.find(recording)?.id ?? entries[0]?.id),
    );
    return [...entries, ...page.active];
  }, [offset]);
  useEffect(() => {
    void refresh().catch((problem) => setError(String(problem)));
  }, [refresh]);
  const currentSummary = [...rows, ...activeRows].find(
    (row) => row.id === selected,
  );
  useEffect(() => {
    if (!selected) {
      setCurrent(undefined);
      setDraft(undefined);
      return;
    }
    let disposed = false;
    void commands
      .meetingGet(selected)
      .then((result) => {
        if (disposed) return;
        const detail = unwrap(result);
        setCurrent(detail);
        if (!dirtyRef.current) setDraft(detail);
      })
      .catch((problem) => {
        if (!disposed) setError(String(problem));
      });
    return () => {
      disposed = true;
    };
  }, [
    selected,
    currentSummary?.status,
    currentSummary?.duration_ms,
    currentSummary?.completed_ms,
  ]);
  useEffect(() => {
    if (
      !activeRows.some(
        (row) =>
          row.status === "recording" ||
          row.status === "paused" ||
          processing(row),
      )
    )
      return;
    let running = false;
    const interval = window.setInterval(() => {
      if (running) return;
      running = true;
      void refresh()
        .catch((problem) => setError(String(problem)))
        .finally(() => {
          running = false;
        });
    }, 1000);
    return () => window.clearInterval(interval);
  }, [refresh, activeRows]);
  const active = activeRows.find(recording);
  const busy = !!current && (recording(current) || processing(current));
  useEffect(() => {
    setAudio(undefined);
    if (
      !selected ||
      !current ||
      recording(current) ||
      current.duration_ms === 0
    )
      return;
    let disposed = false;
    void commands.meetingAudio(selected).then((result) => {
      if (!disposed && result.status === "ok")
        setAudio(convertFileSrc(result.data));
    });
    return () => {
      disposed = true;
    };
  }, [selected, current?.duration_ms, current?.status]);
  const act = async (action: () => Promise<void>) => {
    setPending(true);
    setError(undefined);
    setDurabilityWarning(undefined);
    try {
      await action();
      const entries = await refresh();
      const id = selectedRef.current;
      if (id && entries.some((row) => row.id === id)) {
        const detail = unwrap(await commands.meetingGet(id));
        if (selectedRef.current === id) {
          setCurrent(detail);
          if (!dirtyRef.current) setDraft(detail);
        }
      }
    } catch (problem) {
      setError(String(problem));
    } finally {
      setPending(false);
    }
  };
  const labels = (): [string, string, string] => [
    t("meetings.discussion"),
    t("meetings.decisions"),
    t("meetings.actions"),
  ];
  const process = async (meeting: Meeting) => {
    unwrap(
      await commands.meetingProcess(
        meeting.id,
        meeting.transcript_complete,
        labels(),
      ),
    );
  };
  const control = (meeting: { id: string }, action: MeetingControl) =>
    void act(async () => {
      unwrap(await commands.meetingControl(meeting.id, action));
      if (action === "stop") {
        const stopped = unwrap(await commands.meetingGet(meeting.id));
        if (
          stopped &&
          !stopped.capture_error &&
          stopped.status !== "recoverable"
        )
          await process(stopped);
      }
    });
  const change = (value: Meeting) => {
    dirtyRef.current = true;
    setDirty(true);
    setDraft(value);
  };
  const choose = (id: string) => {
    if (dirty) return;
    setSelected(id);
    setConfirmDelete(false);
  };
  const navigate = (section: string) =>
    window.dispatchEvent(
      new CustomEvent("yanyu-settings-section", { detail: section }),
    );
  const displayedError = error || current?.error || current?.capture_error;
  const errorKey =
    displayedError &&
    t(`meetings.errors.${displayedError}`, {
      defaultValue: t("meetings.errors.processing_failed"),
    });
  return (
    <section className="w-full max-w-3xl space-y-5 text-text select-text">
      <header>
        <h1 className="text-xl font-semibold">{t("meetings.title")}</h1>
        <p className="mt-2 text-sm text-text/65">{t("meetings.privacy")}</p>
      </header>
      <p className="rounded-lg bg-warning/10 p-3 text-sm">
        {t("meetings.qualityWarning")}
      </p>
      {setup && !setup.available && (
        <p role="status" className="rounded-lg bg-warning/10 p-3">
          {t("meetings.unsupported")}
        </p>
      )}
      {setup && (!setup.moss_installed || !setup.qwen_installed) && (
        <div className="rounded-lg border border-warning/40 p-3 space-y-2">
          <p>{t("meetings.modelGuidance")}</p>
          <div className="flex gap-2">
            <Button variant="secondary" onClick={() => navigate("models")}>
              {t("meetings.openModels")}
            </Button>
            <Button variant="secondary" onClick={() => navigate("general")}>
              {t("meetings.openPolishing")}
            </Button>
          </div>
        </div>
      )}
      {displayedError && (
        <div role="alert" className="rounded-lg border border-warning/50 p-3">
          <p>{errorKey}</p>
          <details>
            <summary>{t("meetings.details")}</summary>
            <pre className="whitespace-pre-wrap text-xs">{displayedError}</pre>
          </details>
        </div>
      )}
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex items-center gap-2">
          <span id="meeting-mode-label">{t("meetings.mode")}</span>
          <Dropdown
            aria-labelledby="meeting-mode-label"
            selectedValue={mode}
            disabled={pending || !!active || !setup?.available}
            onSelect={(value) => setMode(value as MeetingMode)}
            options={[
              { value: "in_person", label: t("meetings.inPerson") },
              { value: "online", label: t("meetings.online") },
            ]}
          />
        </div>
        <Button
          disabled={pending || !!active || !setup?.available || dirty}
          onClick={() =>
            void act(async () => {
              const meeting = unwrap(await commands.meetingStart(mode));
              setSelected(meeting.id);
            })
          }
        >
          {t("meetings.start")}
        </Button>
      </div>
      <p className="text-sm text-text/65">{t("meetings.permissions")}</p>
      {active && (
        <div className="rounded-lg border border-logo-primary/40 p-3 space-y-3">
          <p aria-live="polite">
            {t(`meetings.status.${active.status}`)} · {time(active.duration_ms)}
          </p>
          <div className="flex gap-2">
            <Button
              disabled={pending}
              onClick={() =>
                control(active, active.status === "paused" ? "resume" : "pause")
              }
            >
              {t(
                active.status === "paused"
                  ? "meetings.resume"
                  : "meetings.pause",
              )}
            </Button>
            <Button disabled={pending} onClick={() => control(active, "stop")}>
              {t("meetings.stop")}
            </Button>
          </div>
        </div>
      )}
      <div className="space-y-2" aria-label={t("meetings.history")}>
        <h2 className="font-semibold">{t("meetings.history")}</h2>
        {!rows.length && <p>{t("meetings.empty")}</p>}
        {[
          ...activeRows.filter(
            (active) => !rows.some((row) => row.id === active.id),
          ),
          ...rows,
        ].map((row) => (
          <button
            type="button"
            key={row.id}
            aria-label={
              row.title ||
              t("meetings.untitled", {
                date: new Date(row.created_at).toLocaleString(),
              })
            }
            disabled={dirty && row.id !== selected}
            aria-pressed={selected === row.id}
            className={`block w-full rounded-xl border p-3 text-start ${selected === row.id ? "border-[var(--workspace-accent)] bg-[var(--workspace-accent-soft)]" : "border-mid-gray/20 hover:border-[var(--workspace-accent)] hover:bg-mid-gray/5"}`}
            onClick={() => choose(row.id)}
          >
            <span>
              {row.title ||
                t("meetings.untitled", {
                  date: new Date(row.created_at).toLocaleString(),
                })}
            </span>
            <span className="block text-xs text-text/60">
              {t(`meetings.status.${row.status}`)} · {time(row.duration_ms)}
            </span>
          </button>
        ))}
      </div>
      <div className="flex gap-2">
        <Button
          variant="secondary"
          disabled={offset === 0 || pending || dirty}
          onClick={() => setOffset(Math.max(0, offset - 50))}
        >
          {t("meetings.previousPage")}
        </Button>
        <Button
          variant="secondary"
          disabled={!hasMore || pending || dirty}
          onClick={() => setOffset(offset + 50)}
        >
          {t("meetings.nextPage")}
        </Button>
      </div>
      {draft && current && draft.id === current.id && (
        <article className="rounded-lg border border-mid-gray/20 p-4 space-y-4">
          <p role="status" aria-live="polite">
            {t(`meetings.status.${current.status}`)}
            {processing(current) &&
              ` · ${time(current.completed_ms)} / ${time(current.duration_ms)}`}
          </p>
          {durabilityWarning && (
            <p role="alert" className="text-warning">
              {t("meetings.durabilityWarning")} <span>{durabilityWarning}</span>
            </p>
          )}
          <label className="block">
            {t("meetings.meetingTitle")}
            <input
              className="mt-1 block w-full rounded border border-mid-gray/30 bg-background p-2"
              maxLength={200}
              value={draft.title}
              disabled={busy || pending}
              onChange={(event) =>
                change({ ...draft, title: event.target.value })
              }
            />
          </label>
          {audio && (
            <audio
              ref={player}
              controls
              preload="metadata"
              src={audio}
              className="w-full"
              aria-label={t("meetings.recording")}
            />
          )}
          {current.capture_error && (
            <p role="status" className="text-warning">
              {t("meetings.captureIncomplete")}
            </p>
          )}
          {current.status === "recoverable" && <p>{t("meetings.recovered")}</p>}
          {Object.entries(draft.speakers).map(([id, name]) => (
            <label className="block" key={id}>
              {t("meetings.speakerName", { id })}
              <input
                className="ms-2 rounded border border-mid-gray/30 bg-background p-2"
                value={name ?? ""}
                maxLength={100}
                disabled={busy || pending}
                onChange={(event) =>
                  change({
                    ...draft,
                    speakers: { ...draft.speakers, [id]: event.target.value },
                  })
                }
              />
            </label>
          ))}
          <h2 className="font-semibold">{t("meetings.transcript")}</h2>
          {draft.segments.map((segment, index) => (
            <div id={segment.id} key={segment.id} className="space-y-1">
              <div className="flex gap-2 items-center">
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={!audio}
                  onClick={() => {
                    if (player.current) {
                      player.current.currentTime = segment.start_ms / 1000;
                      void player.current
                        .play()
                        .catch(() => setError("playback_failed"));
                    }
                  }}
                >
                  {time(segment.start_ms)}
                </Button>
                <span className="text-sm">
                  {segment.speaker
                    ? draft.speakers[segment.speaker]
                    : t("meetings.unknownSpeaker")}
                </span>
                {segment.uncertain && (
                  <span className="text-xs text-warning">
                    {t("meetings.uncertain")}
                  </span>
                )}
              </div>
              <textarea
                aria-label={t("meetings.segmentLabel", {
                  time: time(segment.start_ms),
                })}
                className="w-full rounded border border-mid-gray/30 bg-background p-2"
                value={segment.text}
                disabled={busy || pending}
                onChange={(event) =>
                  change({
                    ...draft,
                    segments: draft.segments.map((row, position) =>
                      position === index
                        ? { ...row, text: event.target.value }
                        : row,
                    ),
                  })
                }
              />
            </div>
          ))}
          {(draft.notes_stale ||
            (dirty &&
              draft.segments.some(
                (row, index) => row.text !== current.segments[index]?.text,
              ))) && <p className="text-warning">{t("meetings.stale")}</p>}
          <p className="text-sm text-warning">{t("meetings.notesDraft")}</p>
          <label className="block font-semibold">
            {t("meetings.notes")}
            <textarea
              className="mt-1 w-full rounded border border-mid-gray/30 bg-background p-2 font-normal min-h-40"
              value={draft.notes}
              disabled={busy || pending}
              onChange={(event) =>
                change({ ...draft, notes: event.target.value })
              }
            />
          </label>
          <div className="flex flex-wrap gap-2">
            <Button
              disabled={pending || busy || !dirty}
              onClick={() =>
                void act(async () => {
                  const saved = unwrap(await commands.meetingEdit(draft));
                  dirtyRef.current = false;
                  setDirty(false);
                  setDraft(saved);
                  setCurrent(saved);
                  setDurabilityWarning(saved.durability_warning ?? undefined);
                })
              }
            >
              {t("meetings.save")}
            </Button>
            {dirty && (
              <Button
                variant="secondary"
                disabled={pending}
                onClick={() => {
                  dirtyRef.current = false;
                  setDirty(false);
                  setDraft(current);
                }}
              >
                {t("meetings.discard")}
              </Button>
            )}
            {!busy && (
              <Button
                variant="secondary"
                disabled={
                  pending ||
                  dirty ||
                  (!current.transcript_complete && !setup?.moss_installed) ||
                  !setup?.qwen_installed ||
                  !setup?.available
                }
                onClick={() => void act(() => process(current))}
              >
                {t(
                  current.transcript_complete
                    ? "meetings.regenerate"
                    : "meetings.process",
                )}
              </Button>
            )}
            {processing(current) && (
              <Button
                variant="secondary"
                disabled={pending}
                onClick={() => control(current, "cancel")}
              >
                {t("meetings.cancelProcessing")}
              </Button>
            )}
            <Button
              variant="secondary"
              disabled={pending || dirty || busy}
              onClick={() =>
                void act(async () => {
                  unwrap(await commands.meetingExport(current.id));
                })
              }
            >
              {t("meetings.export")}
            </Button>
            <Button
              variant="danger-ghost"
              disabled={pending || busy || dirty}
              onClick={() => setConfirmDelete(true)}
            >
              {t("meetings.delete")}
            </Button>
          </div>
          <Dialog
            open={confirmDelete}
            onOpenChange={setConfirmDelete}
            title={t("meetings.delete")}
            closeLabel={t("meetings.cancel")}
            showCloseButton={false}
            dismissible={!pending}
          >
            <p>{t("meetings.deleteConfirm")}</p>
            <Button
              variant="danger"
              disabled={pending}
              onClick={() =>
                void act(async () => {
                  unwrap(await commands.meetingDelete(current.id));
                  setSelected(undefined);
                  setConfirmDelete(false);
                })
              }
            >
              {t("meetings.deletePermanently")}
            </Button>
            <Button
              variant="secondary"
              disabled={pending}
              onClick={() => setConfirmDelete(false)}
            >
              {t("meetings.cancel")}
            </Button>
          </Dialog>
        </article>
      )}
    </section>
  );
}

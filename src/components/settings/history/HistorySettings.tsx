import React, {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { readFile } from "@tauri-apps/plugin-fs";
import {
  Check,
  Copy,
  FolderOpen,
  Pencil,
  RotateCcw,
  Star,
  Trash2,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import {
  commands,
  events,
  type HistoryEntry,
  type HistoryUpdatePayload,
} from "@/bindings";
import { useOsType } from "@/hooks/useOsType";
import { formatDateTime } from "@/utils/dateFormat";
import { AudioPlayer, AudioPlayerGroup } from "../../ui/AudioPlayer";
import { Button } from "../../ui/Button";
import { copyToClipboard } from "./clipboard";
import { useSettings } from "@/hooks/useSettings";
import {
  getCustomWordValidationError,
  normalizeCustomWord,
} from "@/utils/customWord";

const IconButton: React.FC<{
  onClick: () => void;
  title: string;
  disabled?: boolean;
  active?: boolean;
  children: React.ReactNode;
}> = ({ onClick, title, disabled, active, children }) => (
  <button
    onClick={onClick}
    disabled={disabled}
    className={`p-1.5 rounded-md flex items-center justify-center transition-colors cursor-pointer disabled:cursor-not-allowed disabled:text-text/20 ${
      active
        ? "text-logo-primary hover:text-logo-primary/80"
        : "text-text/50 hover:text-logo-primary"
    }`}
    title={title}
  >
    {children}
  </button>
);

const PAGE_SIZE = 30;

interface OpenRecordingsButtonProps {
  onClick: () => void;
  label: string;
}

const OpenRecordingsButton: React.FC<OpenRecordingsButtonProps> = ({
  onClick,
  label,
}) => (
  <Button
    onClick={onClick}
    variant="secondary"
    size="sm"
    className="flex items-center gap-2"
    title={label}
  >
    <FolderOpen className="w-4 h-4" />
    <span>{label}</span>
  </Button>
);

export const HistorySettings: React.FC = () => {
  const { t } = useTranslation();
  const osType = useOsType();
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(true);
  const sentinelRef = useRef<HTMLDivElement>(null);
  const entriesRef = useRef<HistoryEntry[]>([]);
  const loadingRef = useRef(false);

  // Keep ref in sync for use in IntersectionObserver callback
  useEffect(() => {
    entriesRef.current = entries;
  }, [entries]);

  const loadPage = useCallback(async (cursor?: number) => {
    const isFirstPage = cursor === undefined;
    if (!isFirstPage && loadingRef.current) return;
    loadingRef.current = true;

    if (isFirstPage) setLoading(true);

    try {
      const result = await commands.getHistoryEntries(
        cursor ?? null,
        PAGE_SIZE,
      );
      if (result.status === "ok") {
        const { entries: newEntries, has_more } = result.data;
        setEntries((prev) =>
          isFirstPage ? newEntries : [...prev, ...newEntries],
        );
        setHasMore(has_more);
      }
    } catch (error) {
      console.error("Failed to load history entries:", error);
    } finally {
      setLoading(false);
      loadingRef.current = false;
    }
  }, []);

  // Initial load
  useEffect(() => {
    loadPage();
  }, [loadPage]);

  // Infinite scroll via IntersectionObserver
  useEffect(() => {
    if (loading) return;

    const sentinel = sentinelRef.current;
    if (!sentinel || !hasMore) return;

    const observer = new IntersectionObserver(
      (observerEntries) => {
        const first = observerEntries[0];
        if (first.isIntersecting) {
          const lastEntry = entriesRef.current[entriesRef.current.length - 1];
          if (lastEntry) {
            loadPage(lastEntry.id);
          }
        }
      },
      { threshold: 0 },
    );

    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [loading, hasMore, loadPage]);

  // Listen for new entries added from the transcription pipeline
  useEffect(() => {
    const unlisten = events.historyUpdatePayload.listen((event) => {
      const payload: HistoryUpdatePayload = event.payload;
      if (payload.action === "added") {
        setEntries((prev) => [payload.entry, ...prev]);
      } else if (payload.action === "updated") {
        setEntries((prev) =>
          prev.map((e) => (e.id === payload.entry.id ? payload.entry : e)),
        );
      }
      // "deleted" and "toggled" are handled by optimistic updates only,
      // so we intentionally ignore them here to avoid double-mutation.
    });

    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const toggleSaved = async (id: number) => {
    // Optimistic update
    setEntries((prev) =>
      prev.map((e) => (e.id === id ? { ...e, saved: !e.saved } : e)),
    );
    try {
      const result = await commands.toggleHistoryEntrySaved(id);
      if (result.status !== "ok") {
        // Revert on failure
        setEntries((prev) =>
          prev.map((e) => (e.id === id ? { ...e, saved: !e.saved } : e)),
        );
      }
    } catch (error) {
      console.error("Failed to toggle saved status:", error);
      // Revert on failure
      setEntries((prev) =>
        prev.map((e) => (e.id === id ? { ...e, saved: !e.saved } : e)),
      );
    }
  };

  const getAudioUrl = useCallback(
    async (fileName: string) => {
      try {
        const result = await commands.getAudioFilePath(fileName);
        if (result.status === "ok") {
          if (osType === "linux") {
            const fileData = await readFile(result.data);
            const blob = new Blob([fileData], { type: "audio/wav" });
            return URL.createObjectURL(blob);
          }
          return convertFileSrc(result.data, "asset");
        }
        return null;
      } catch (error) {
        console.error("Failed to get audio file path:", error);
        return null;
      }
    },
    [osType],
  );

  const deleteAudioEntry = async (id: number) => {
    // Optimistically remove
    setEntries((prev) => prev.filter((e) => e.id !== id));
    try {
      const result = await commands.deleteHistoryEntry(id);
      if (result.status !== "ok") {
        // Reload on failure
        loadPage();
      }
    } catch (error) {
      console.error("Failed to delete entry:", error);
      loadPage();
    }
  };

  const retryHistoryEntry = async (id: number) => {
    const result = await commands.retryHistoryEntryTranscription(id);
    if (result.status !== "ok") {
      throw new Error(String(result.error));
    }
  };

  const saveCorrection = async (id: number, text: string) => {
    const result = await commands.updateHistoryEntryCorrection(id, text);
    if (result.status !== "ok") throw new Error(String(result.error));
    setEntries((prev) =>
      prev.map((entry) => (entry.id === id ? result.data : entry)),
    );
  };

  const openRecordingsFolder = async () => {
    try {
      const result = await commands.openRecordingsFolder();
      if (result.status !== "ok") {
        throw new Error(String(result.error));
      }
    } catch (error) {
      console.error("Failed to open recordings folder:", error);
    }
  };

  let content: React.ReactNode;

  if (loading) {
    content = (
      <div className="px-4 py-3 text-center text-text/60">
        {t("settings.history.loading")}
      </div>
    );
  } else if (entries.length === 0) {
    content = (
      <div className="px-4 py-3 text-center text-text/60">
        {t("settings.history.empty")}
      </div>
    );
  } else {
    content = (
      <>
        <AudioPlayerGroup>
          <div className="divide-y divide-mid-gray/20">
            {entries.map((entry) => (
              <HistoryEntryComponent
                key={entry.id}
                entry={entry}
                onToggleSaved={() => toggleSaved(entry.id)}
                onCopyText={() => copyToClipboard(getDisplayText(entry))}
                getAudioUrl={getAudioUrl}
                deleteAudio={deleteAudioEntry}
                retryTranscription={retryHistoryEntry}
                saveCorrection={saveCorrection}
              />
            ))}
          </div>
        </AudioPlayerGroup>
        {/* Sentinel for infinite scroll */}
        <div ref={sentinelRef} className="h-1" />
      </>
    );
  }

  return (
    <div className="max-w-3xl w-full mx-auto space-y-6">
      <div className="space-y-2">
        <div className="px-4 flex items-center justify-between">
          <div>
            <h2 className="text-xs font-medium text-mid-gray uppercase tracking-wide">
              {t("settings.history.title")}
            </h2>
          </div>
          <OpenRecordingsButton
            onClick={openRecordingsFolder}
            label={t("settings.history.openFolder")}
          />
        </div>
        <div className="settings-card border border-mid-gray/20 rounded-xl overflow-visible">
          {content}
        </div>
      </div>
    </div>
  );
};

// Corrections preserve exact user text; unedited entries retain the polishing fallback.
const getDisplayText = (entry: HistoryEntry) =>
  entry.user_corrected_text ??
  (entry.post_processed_text?.trim() || entry.transcription_text);

interface HistoryEntryProps {
  entry: HistoryEntry;
  onToggleSaved: () => void;
  onCopyText: () => Promise<boolean>;
  getAudioUrl: (fileName: string) => Promise<string | null>;
  deleteAudio: (id: number) => Promise<void>;
  retryTranscription: (id: number) => Promise<void>;
  saveCorrection: (id: number, text: string) => Promise<void>;
}

const HistoryEntryComponent: React.FC<HistoryEntryProps> = ({
  entry,
  onToggleSaved,
  onCopyText,
  getAudioUrl,
  deleteAudio,
  retryTranscription,
  saveCorrection,
}) => {
  const { t, i18n } = useTranslation();
  const { getSetting, updateCustomWords, isUpdating } = useSettings();
  const [showCopied, setShowCopied] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [selectedCorrection, setSelectedCorrection] = useState("");
  const [vocabularyError, setVocabularyError] = useState<string | null>(null);
  const [vocabularyStatus, setVocabularyStatus] = useState<string | null>(null);
  const correctedTextRef = useRef<HTMLTextAreaElement>(null);
  const editorId = useId();

  const hasTranscription = entry.transcription_text.trim().length > 0;
  const displayText = getDisplayText(entry);
  const selectionValidationError =
    getCustomWordValidationError(selectedCorrection);
  const captureCorrectionSelection = () => {
    const correctedText = correctedTextRef.current;
    if (!correctedText) return;
    if (correctedText.selectionStart === correctedText.selectionEnd) {
      if (document.activeElement === correctedText) setSelectedCorrection("");
      return;
    }
    setSelectedCorrection(
      correctedText.value.slice(
        correctedText.selectionStart,
        correctedText.selectionEnd,
      ),
    );
    setVocabularyError(null);
    setVocabularyStatus(null);
  };

  useEffect(() => {
    setSelectedCorrection("");
    setVocabularyError(null);
    setVocabularyStatus(null);
  }, [displayText, editing, retrying]);

  useLayoutEffect(() => {
    const correctedText = correctedTextRef.current;
    if (!correctedText) return;
    const fitHeight = () => {
      correctedText.style.height = "auto";
      correctedText.style.height = `${correctedText.scrollHeight}px`;
    };
    fitHeight();
    let previousWidth = correctedText.getBoundingClientRect().width;
    const observer = new ResizeObserver(([entry]) => {
      // Height updates must not trigger another measurement.
      if (entry.contentRect.width === previousWidth) return;
      previousWidth = entry.contentRect.width;
      fitHeight();
    });
    observer.observe(correctedText);
    return () => observer.disconnect();
  }, [displayText, entry.user_corrected_text, retrying]);

  const clearSelectionOutsideVocabularyAction = (
    event: React.FocusEvent<HTMLDivElement>,
  ) => {
    if (!event.currentTarget.contains(event.relatedTarget)) {
      setSelectedCorrection("");
    }
  };

  const handleAddCorrectionToVocabulary = async () => {
    if (!selectedCorrection || isUpdating("custom_words")) return;
    if (selectionValidationError) {
      setVocabularyError(selectionValidationError);
      return;
    }
    const word = normalizeCustomWord(selectedCorrection);
    const customWords = getSetting("custom_words") || [];
    if (customWords.includes(word)) {
      setVocabularyError("duplicate");
      return;
    }
    setVocabularyError(null);
    setVocabularyStatus(null);
    try {
      await updateCustomWords([...customWords, word]);
      setSelectedCorrection("");
      window.getSelection()?.removeAllRanges();
      setVocabularyStatus("added");
    } catch {
      setVocabularyError("updateFailed");
    }
  };
  const originalText =
    displayText !== entry.transcription_text ? entry.transcription_text : null;

  const handleLoadAudio = useCallback(
    () => getAudioUrl(entry.file_name),
    [getAudioUrl, entry.file_name],
  );

  const handleCopyText = async () => {
    if (!hasTranscription || retrying || saving) {
      return;
    }

    const copied = await onCopyText();
    if (!copied) {
      toast.error(t("settings.history.copyError"));
      return;
    }

    setShowCopied(true);
    setTimeout(() => setShowCopied(false), 2000);
  };

  const handleSaveCorrection = async () => {
    if (saving || retrying) return;
    if (!draft.trim()) {
      setSaveError(t("settings.history.correctionRequired"));
      return;
    }
    setSaving(true);
    setSaveError(null);
    try {
      await saveCorrection(entry.id, draft);
      setEditing(false);
    } catch (error) {
      console.error("Failed to save transcript:", error);
      setSaveError(t("settings.history.correctionSaveError"));
    } finally {
      setSaving(false);
    }
  };

  const handleDeleteEntry = async () => {
    try {
      await deleteAudio(entry.id);
    } catch (error) {
      console.error("Failed to delete entry:", error);
      toast.error(t("settings.history.deleteError"));
    }
  };

  const handleRetranscribe = async () => {
    try {
      setRetrying(true);
      await retryTranscription(entry.id);
    } catch (error) {
      console.error("Failed to re-transcribe:", error);
      toast.error(t("settings.history.retranscribeError"));
    } finally {
      setRetrying(false);
    }
  };

  const formattedDate = formatDateTime(String(entry.timestamp), i18n.language);

  return (
    <div className="px-4 py-2 pb-5 flex flex-col gap-3">
      <div className="flex justify-between items-center">
        <p className="text-sm font-medium">{formattedDate}</p>
        <div className="flex items-center">
          {hasTranscription && displayText.trim() && (
            <IconButton
              onClick={() => {
                setDraft(displayText);
                setSaveError(null);
                setEditing(true);
              }}
              disabled={retrying || saving || editing}
              title={t("settings.history.editTranscript")}
            >
              <Pencil width={16} height={16} />
            </IconButton>
          )}
          <IconButton
            onClick={handleCopyText}
            disabled={!hasTranscription || retrying || saving}
            title={t("settings.history.copyToClipboard")}
          >
            {showCopied ? (
              <Check width={16} height={16} />
            ) : (
              <Copy width={16} height={16} />
            )}
          </IconButton>
          <IconButton
            onClick={onToggleSaved}
            disabled={retrying || saving}
            active={entry.saved}
            title={
              entry.saved
                ? t("settings.history.unsave")
                : t("settings.history.save")
            }
          >
            <Star
              width={16}
              height={16}
              fill={entry.saved ? "currentColor" : "none"}
            />
          </IconButton>
          <IconButton
            onClick={handleRetranscribe}
            disabled={retrying || saving}
            title={t("settings.history.retranscribe")}
          >
            <RotateCcw
              width={16}
              height={16}
              style={
                retrying
                  ? { animation: "spin 1s linear infinite reverse" }
                  : undefined
              }
            />
          </IconButton>
          <IconButton
            onClick={handleDeleteEntry}
            disabled={retrying || saving}
            title={t("settings.history.delete")}
          >
            <Trash2 width={16} height={16} />
          </IconButton>
        </div>
      </div>

      {editing && (
        <div className="space-y-2">
          <label htmlFor={editorId} className="text-sm font-medium">
            {t("settings.history.correctedTranscript")}
          </label>
          <textarea
            id={editorId}
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            disabled={saving}
            aria-invalid={!!saveError}
            aria-describedby={saveError ? `${editorId}-error` : undefined}
            rows={4}
            className="w-full rounded-md border border-mid-gray/40 bg-background p-2 text-sm resize-y"
          />
          {saveError && (
            <p
              id={`${editorId}-error`}
              role="alert"
              className="text-sm text-red-500"
            >
              {saveError}
            </p>
          )}
          <div className="flex gap-2">
            <Button
              size="sm"
              onClick={handleSaveCorrection}
              disabled={saving || retrying}
            >
              {t("settings.history.saveCorrection")}
            </Button>
            <Button
              size="sm"
              variant="secondary"
              onClick={() => setEditing(false)}
              disabled={saving}
            >
              {t("tray.cancel")}
            </Button>
          </div>
        </div>
      )}

      <div
        onBlur={clearSelectionOutsideVocabularyAction}
        className="flex flex-col gap-3"
      >
        {entry.user_corrected_text !== null && !retrying ? (
          <textarea
            key={`${entry.id}:${displayText}`}
            ref={correctedTextRef}
            aria-label={t("settings.history.savedCorrectionText")}
            defaultValue={displayText}
            readOnly
            spellCheck={false}
            rows={Math.max(1, displayText.split("\n").length)}
            onSelect={captureCorrectionSelection}
            onMouseUp={captureCorrectionSelection}
            onKeyUp={captureCorrectionSelection}
            className="w-full resize-none overflow-hidden bg-transparent p-0 pb-2 text-sm italic text-text/90 focus-visible:rounded-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-logo-primary"
          />
        ) : (
          <p
            className={`italic text-sm pb-2 ${
              retrying
                ? ""
                : hasTranscription
                  ? "text-text/90 select-text cursor-text whitespace-pre-wrap break-words"
                  : "text-text/40"
            }`}
            style={
              retrying
                ? { animation: "transcribe-pulse 3s ease-in-out infinite" }
                : undefined
            }
          >
            {retrying && (
              <style>{`
              @keyframes transcribe-pulse {
                0%, 100% { color: color-mix(in srgb, var(--color-text) 40%, transparent); }
                50% { color: color-mix(in srgb, var(--color-text) 90%, transparent); }
              }
            `}</style>
            )}
            {retrying
              ? t("settings.history.transcribing")
              : hasTranscription
                ? displayText
                : t("settings.history.transcriptionFailed")}
          </p>
        )}

        {entry.user_corrected_text !== null && !retrying && !editing && (
          <div className="flex flex-col items-start gap-1 -mt-2">
            <Button
              size="sm"
              variant="secondary"
              onMouseDown={(event) => {
                // Safari does not focus buttons on mouse activation.
                event.preventDefault();
                event.currentTarget.focus();
              }}
              onClick={handleAddCorrectionToVocabulary}
              disabled={!selectedCorrection || isUpdating("custom_words")}
            >
              {t("settings.history.addToVocabulary")}
            </Button>
            {selectionValidationError && (
              <p role="alert" className="text-sm text-red-500">
                {t(`settings.advanced.customWords.${selectionValidationError}`)}
              </p>
            )}
            {vocabularyError && (
              <p role="alert" className="text-sm text-red-500">
                {vocabularyError === "duplicate"
                  ? t("settings.advanced.customWords.duplicate", {
                      word: normalizeCustomWord(selectedCorrection),
                    })
                  : t(`settings.advanced.customWords.${vocabularyError}`)}
              </p>
            )}
            {vocabularyStatus && (
              <p role="status" className="text-sm">
                {t("settings.history.vocabularyAdded")}
              </p>
            )}
          </div>
        )}
      </div>

      {!retrying && (originalText || entry.user_corrected_text !== null) && (
        <div className="border-l-2 border-mid-gray/30 pl-3 -mt-2 pb-2">
          <p className="text-xs text-mid-gray mb-1">
            {t(
              entry.user_corrected_text !== null
                ? "settings.history.recognizedText"
                : "settings.history.beforePolishing",
            )}
          </p>
          <p className="text-sm text-text/50 select-text cursor-text whitespace-pre-wrap break-words">
            {entry.transcription_text}
          </p>
        </div>
      )}

      {!retrying &&
        entry.user_corrected_text !== null &&
        entry.post_processed_text !== null && (
          <div className="border-l-2 border-mid-gray/30 pl-3 -mt-2 pb-2">
            <p className="text-xs text-mid-gray mb-1">
              {t("settings.history.polishedText")}
            </p>
            <p className="text-sm text-text/50 select-text cursor-text whitespace-pre-wrap break-words">
              {entry.post_processed_text}
            </p>
          </div>
        )}

      {!retrying &&
        entry.user_corrected_text === null &&
        !originalText &&
        entry.post_processed_text?.trim() === entry.transcription_text && (
          <p className="text-xs text-mid-gray -mt-2 pb-2">
            {t("settings.history.polishingUnchanged")}
          </p>
        )}

      {!retrying && entry.post_process_skip_reason && (
        <p className="text-xs text-mid-gray -mt-2 pb-2">
          {t("settings.history.polishingSkipped")}:{" "}
          {t(`settings.history.skipReasons.${entry.post_process_skip_reason}`, {
            defaultValue: entry.post_process_skip_reason,
          })}
        </p>
      )}

      <AudioPlayer onLoadRequest={handleLoadAudio} className="w-full" />
    </div>
  );
};

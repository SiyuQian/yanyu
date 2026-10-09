import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { Sparkles } from "lucide-react";
import { commands, type LocalPolishingStatus } from "@/bindings";
import { useSettings } from "@/hooks/useSettings";
import { useSettingsStore } from "@/stores/settingsStore";
import { SettingsGroup } from "@/components/ui/SettingsGroup";
import { Button } from "@/components/ui/Button";
import { ToggleSwitch } from "@/components/ui/ToggleSwitch";

export function LocalPolishingSettings() {
  const { t } = useTranslation();
  const { getSetting, updateSetting, isUpdating } = useSettings();
  const [status, setStatus] = useState<LocalPolishingStatus | null>(null);
  const [error, setError] = useState(false);
  const [pending, setPending] = useState(false);

  useEffect(() => {
    let active = true;
    let fetching = false;
    const refresh = async () => {
      if (fetching) return;
      fetching = true;
      try {
        const result = await commands.getLocalPolishingStatus();
        if (active) setStatus(result);
      } catch {
        if (active) setError(true);
      } finally {
        fetching = false;
      }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 500);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, []);

  const act = async (action: "download" | "cancel" | "delete") => {
    setPending(true);
    setError(false);
    try {
      if (action === "cancel") {
        await commands.cancelLocalPolishingDownload();
      } else {
        const result = await (action === "download"
          ? commands.downloadLocalPolishingModel()
          : commands.deleteLocalPolishingModel());
        if (result.status === "error") throw new Error(result.error);
        if (action === "delete") {
          await useSettingsStore.getState().refreshSettings();
        }
      }
      setStatus(await commands.getLocalPolishingStatus());
    } catch {
      setError(true);
    } finally {
      setPending(false);
    }
  };
  const downloading = status?.phase === "downloading";

  return (
    <SettingsGroup
      variant="card"
      icon={<Sparkles size={20} />}
      title={t("settings.localPolishing.title")}
    >
      <ToggleSwitch
        checked={getSetting("local_polishing_enabled") ?? false}
        onChange={(enabled) =>
          updateSetting("local_polishing_enabled", enabled)
        }
        isUpdating={isUpdating("local_polishing_enabled")}
        disabled={!status?.supported}
        label={t("settings.localPolishing.label")}
        description={t("settings.localPolishing.description")}
        descriptionMode="inline"
        grouped
      />
      <div className="py-3 space-y-3">
        <p className="text-sm text-text/70" role="status" aria-live="polite">
          {t(`settings.localPolishing.states.${status?.phase ?? "loading"}`)}
        </p>
        {downloading && (
          <progress
            className="w-full"
            value={status?.progress ?? 0}
            max={1}
            aria-label={t("settings.localPolishing.progress")}
          />
        )}
        {(error || status?.error) && (
          <p className="text-sm text-red-500" role="alert">
            {t("settings.localPolishing.error")}
          </p>
        )}
        <div className="flex gap-2">
          {downloading ? (
            <Button
              variant="secondary"
              disabled={pending}
              onClick={() => void act("cancel")}
            >
              {t("settings.localPolishing.cancel")}
            </Button>
          ) : (
            <Button
              variant="secondary"
              disabled={pending || !status?.supported || status.downloaded}
              onClick={() => void act("download")}
            >
              {t("settings.localPolishing.download")}
            </Button>
          )}
          <Button
            variant="danger-ghost"
            disabled={pending || (!status?.downloaded && !downloading)}
            onClick={() => void act("delete")}
          >
            {t("settings.localPolishing.delete")}
          </Button>
        </div>
      </div>
    </SettingsGroup>
  );
}

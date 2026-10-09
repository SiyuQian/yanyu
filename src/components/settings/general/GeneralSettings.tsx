import React from "react";
import { useTranslation } from "react-i18next";
import { type } from "@tauri-apps/plugin-os";
import { Cpu, Keyboard, Volume2 } from "lucide-react";
import { useModelStore } from "../../../stores/modelStore";
import { MicrophoneSelector } from "../MicrophoneSelector";
import { ChannelSelector } from "../ChannelSelector";
import { ShortcutInput } from "../ShortcutInput";
import { SettingsGroup } from "../../ui/SettingsGroup";
import { OutputDeviceSelector } from "../OutputDeviceSelector";
import { ShortcutActivationSetting } from "../ShortcutActivation";
import { AudioFeedback } from "../AudioFeedback";
import { useSettings } from "../../../hooks/useSettings";
import { VolumeSlider } from "../VolumeSlider";
import { MuteWhileRecording } from "../MuteWhileRecording";
import { LocalPolishingSettings } from "./LocalPolishingSettings";
import { ModelSettingsCard } from "./ModelSettingsCard";

export const GeneralSettings: React.FC = () => {
  const { t } = useTranslation();
  const { audioFeedbackEnabled } = useSettings();
  const currentModelInfo = useModelStore((state) =>
    state.models.find((model) => model.id === state.currentModel),
  );
  const isLinux = type() === "linux";
  return (
    <div className="dictation-settings max-w-3xl w-full mx-auto space-y-5">
      <header className="flex flex-wrap items-center justify-between gap-4 pb-2">
        <div>
          <h1 className="text-3xl font-semibold tracking-tight">
            {t("sidebar.general")}
          </h1>
          <p className="mt-2 text-sm text-text/60">
            {t("settings.general.pageDescription")}
          </p>
        </div>
        {currentModelInfo && (
          <span className="flex max-w-full items-center gap-2 rounded-lg border border-mid-gray/20 px-3 py-2 text-xs text-text/70">
            <Cpu className="h-4 w-4 shrink-0" aria-hidden="true" />
            <span className="truncate">{currentModelInfo.name}</span>
          </span>
        )}
      </header>
      <SettingsGroup
        variant="card"
        icon={<Keyboard size={20} />}
        title={t("settings.general.shortcutsTitle")}
      >
        <ShortcutInput shortcutId="transcribe" grouped={true} />
        <ShortcutActivationSetting descriptionMode="inline" grouped={true} />
        {/* Cancel shortcut remains hidden on Linux because of dynamic shortcut instability. */}
        {!isLinux && <ShortcutInput shortcutId="cancel" grouped={true} />}
      </SettingsGroup>
      <ModelSettingsCard />
      <LocalPolishingSettings />
      <SettingsGroup
        variant="card"
        icon={<Volume2 size={20} />}
        title={t("settings.sound.title")}
      >
        <MicrophoneSelector descriptionMode="tooltip" grouped={true} />
        <ChannelSelector descriptionMode="tooltip" grouped={true} />
        <MuteWhileRecording descriptionMode="tooltip" grouped={true} />
        <AudioFeedback descriptionMode="tooltip" grouped={true} />
        <OutputDeviceSelector
          descriptionMode="tooltip"
          grouped={true}
          disabled={!audioFeedbackEnabled}
        />
        <VolumeSlider disabled={!audioFeedbackEnabled} />
        {!audioFeedbackEnabled && (
          <p className="py-3 text-xs text-text/60">
            {t("settings.sound.audioFeedback.disabledHint")}
          </p>
        )}
      </SettingsGroup>
    </div>
  );
};

import React from "react";
import { useTranslation } from "react-i18next";
import { arch, type } from "@tauri-apps/plugin-os";
import { Keyboard, Volume2 } from "lucide-react";
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
import { PersonalizationSettings } from "./PersonalizationSettings";
import { ModelSettingsCard } from "./ModelSettingsCard";

export const GeneralSettings: React.FC = () => {
  const { t } = useTranslation();
  const { audioFeedbackEnabled } = useSettings();
  const isLinux = type() === "linux";
  return (
    <div className="dictation-settings max-w-3xl w-full mx-auto space-y-5">
      <SettingsGroup
        variant="card"
        icon={<Keyboard size={20} />}
        title={t("settings.general.shortcutsTitle")}
      >
        <ShortcutInput shortcutId="transcribe" grouped={true} />
        {type() === "macos" && arch() === "aarch64" && (
          <>
            <ShortcutInput shortcutId="polish_selection" grouped={true} />
            <ShortcutInput shortcutId="translate_selection" grouped={true} />
          </>
        )}
        <ShortcutActivationSetting descriptionMode="inline" grouped={true} />
        {/* Cancel shortcut remains hidden on Linux because of dynamic shortcut instability. */}
        {!isLinux && <ShortcutInput shortcutId="cancel" grouped={true} />}
      </SettingsGroup>
      <PersonalizationSettings />
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

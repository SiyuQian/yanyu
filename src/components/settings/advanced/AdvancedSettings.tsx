import React, { useEffect, useState } from "react";
import { PostProcessingSettingsPrompts } from "../post-processing/PostProcessingSettings";
import { useTranslation } from "react-i18next";
import { ShowOverlay } from "../ShowOverlay";
import { ModelUnloadTimeoutSetting } from "../ModelUnloadTimeout";
import { SettingsGroup } from "../../ui/SettingsGroup";
import { StartHidden } from "../StartHidden";
import { AutostartToggle } from "../AutostartToggle";
import { ShowTrayIcon } from "../ShowTrayIcon";
import { PasteMethodSetting } from "../PasteMethod";
import { TypingToolSetting } from "../TypingTool";
import { ClipboardHandlingSetting } from "../ClipboardHandling";
import { AutoSubmit } from "../AutoSubmit";
import { ToggleSwitch } from "@/components/ui/ToggleSwitch";
import { AppendTrailingSpace } from "../AppendTrailingSpace";
import { HistoryLimit } from "../HistoryLimit";
import { RecordingRetentionPeriodSelector } from "../RecordingRetentionPeriod";
import { ExperimentalToggle } from "../ExperimentalToggle";
import { useSettings } from "../../../hooks/useSettings";
import { KeyboardImplementationSelector } from "../debug/KeyboardImplementationSelector";
import { VoiceActivityDetection } from "../VoiceActivityDetection";
import { AccelerationSelector } from "../AccelerationSelector";
import { LazyStreamClose } from "../LazyStreamClose";
import { FillerWordRemoval } from "../FillerWordRemoval";
import { ChineseScriptSetting } from "../ChineseScript";
import { VadBackendSelector } from "../VadBackendSelector";
import { commands } from "@/bindings";

export const AdvancedSettings: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, updateSetting, isUpdating } = useSettings();
  const experimentalEnabled = getSetting("experimental_enabled") || false;
  const [localPolishingSupported, setLocalPolishingSupported] = useState<
    boolean | null
  >(null);

  useEffect(() => {
    let active = true;
    void commands
      .getLocalPolishingStatus()
      .then((status) => {
        if (active) setLocalPolishingSupported(status.supported);
      })
      .catch(() => {
        if (active) setLocalPolishingSupported(false);
      });
    return () => {
      active = false;
    };
  }, []);

  return (
    <div className="max-w-3xl w-full mx-auto space-y-6">
      <SettingsGroup title={t("settings.advanced.groups.app")}>
        <StartHidden descriptionMode="tooltip" grouped={true} />
        <AutostartToggle descriptionMode="tooltip" grouped={true} />
        <ShowTrayIcon descriptionMode="tooltip" grouped={true} />
        <ShowOverlay descriptionMode="tooltip" grouped={true} />
        <ModelUnloadTimeoutSetting descriptionMode="tooltip" grouped={true} />
        <ExperimentalToggle descriptionMode="tooltip" grouped={true} />
      </SettingsGroup>

      <SettingsGroup title={t("settings.advanced.groups.output")}>
        <PasteMethodSetting descriptionMode="tooltip" grouped={true} />
        <TypingToolSetting descriptionMode="tooltip" grouped={true} />
        <ClipboardHandlingSetting descriptionMode="tooltip" grouped={true} />
        <AutoSubmit descriptionMode="tooltip" grouped={true} />
      </SettingsGroup>

      <SettingsGroup title={t("settings.advanced.groups.transcription")}>
        <VoiceActivityDetection descriptionMode="tooltip" grouped={true} />
        <FillerWordRemoval descriptionMode="tooltip" grouped={true} />
        <ChineseScriptSetting descriptionMode="tooltip" grouped={true} />
        <AppendTrailingSpace descriptionMode="tooltip" grouped={true} />
      </SettingsGroup>

      <SettingsGroup title={t("settings.advanced.groups.history")}>
        <HistoryLimit descriptionMode="tooltip" grouped={true} />
        <RecordingRetentionPeriodSelector
          descriptionMode="tooltip"
          grouped={true}
        />
      </SettingsGroup>

      <SettingsGroup title={t("settings.postProcessing.prompts.title")}>
        <ToggleSwitch
          checked={getSetting("local_polishing_enabled") ?? false}
          onChange={(enabled) =>
            updateSetting("local_polishing_enabled", enabled)
          }
          disabled={!localPolishingSupported}
          isUpdating={isUpdating("local_polishing_enabled")}
          label={t("settings.localPolishing.label")}
          description={t("settings.localPolishing.description")}
          descriptionMode="inline"
          grouped
        />
        <PostProcessingSettingsPrompts />
      </SettingsGroup>
      {experimentalEnabled && (
        <SettingsGroup title={t("settings.advanced.groups.experimental")}>
          <KeyboardImplementationSelector
            descriptionMode="tooltip"
            grouped={true}
          />
          <AccelerationSelector descriptionMode="tooltip" grouped={true} />
          <LazyStreamClose descriptionMode="tooltip" grouped={true} />
          <VadBackendSelector descriptionMode="tooltip" grouped={true} />
        </SettingsGroup>
      )}
    </div>
  );
};

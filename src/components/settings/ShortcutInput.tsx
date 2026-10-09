import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { X } from "lucide-react";
import { toast } from "sonner";
import { commands, type ShortcutBinding } from "@/bindings";
import { useSettings } from "../../hooks/useSettings";
import { GlobalShortcutInput } from "./GlobalShortcutInput";
import { HandyKeysShortcutInput } from "./HandyKeysShortcutInput";
import { SettingContainer } from "../ui/SettingContainer";
import { ResetButton } from "../ui/ResetButton";

interface ShortcutInputProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
  shortcutId: string;
  disabled?: boolean;
  controlsOnly?: boolean;
  draftBinding?: ShortcutBinding;
  onRecordingChange?: (recording: boolean) => void;
}

/**
 * Wrapper component that selects the appropriate shortcut input implementation
 * based on the keyboard_implementation setting.
 *
 * - "tauri" (default): Uses GlobalShortcutInput with JS keyboard events
 * - "handy_keys": Uses HandyKeysShortcutInput with backend key events
 */
export const ShortcutInput: React.FC<ShortcutInputProps> = (props) => {
  const { getSetting } = useSettings();
  const keyboardImplementation = getSetting("keyboard_implementation");

  if (props.shortcutId === "transcribe" && !props.controlsOnly) {
    return <TranscribeShortcuts {...props} />;
  }

  // Default to Tauri implementation if not set
  if (keyboardImplementation === "handy_keys") {
    return <HandyKeysShortcutInput {...props} />;
  }

  return <GlobalShortcutInput {...props} />;
};

const TranscribeShortcuts: React.FC<ShortcutInputProps> = (props) => {
  const { t } = useTranslation();
  const { getSetting, refreshSettings, resetBinding, isLoading, isUpdating } =
    useSettings();
  const [editingId, setEditingId] = useState<string | null>(null);
  const [removingId, setRemovingId] = useState<string | null>(null);
  const bindings = getSetting("bindings") || {};
  const additionalIds = Object.keys(bindings)
    .filter((id) => /^transcribe_alt_\d+$/.test(id))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
  let next = 1;
  while (bindings[`transcribe_alt_${next}`]) next++;
  const draftId = `transcribe_alt_${next}`;
  const draftBinding: ShortcutBinding = {
    ...bindings.transcribe!,
    id: draftId,
    current_binding: "",
    default_binding: "",
  };
  const busy = props.disabled || isLoading || !!editingId || !!removingId;

  const remove = async (id: string) => {
    setRemovingId(id);
    try {
      const result = await commands.removeTranscribeBinding(id);
      if (result.status === "error") throw new Error(result.error);
      await refreshSettings();
    } catch (error) {
      toast.error(
        t("settings.general.shortcut.errors.set", { error: String(error) }),
      );
    } finally {
      setRemovingId(null);
    }
  };

  return (
    <SettingContainer
      title={t("settings.general.shortcut.bindings.transcribe.name")}
      description={t(
        "settings.general.shortcut.bindings.transcribe.description",
      )}
      descriptionMode={props.descriptionMode}
      grouped={props.grouped}
      disabled={props.disabled}
    >
      <div className="flex flex-wrap items-center justify-end gap-2">
        {["transcribe", ...additionalIds, draftId].map((id) => (
          <div key={id} className="flex items-center gap-1">
            <ShortcutInput
              shortcutId={id}
              controlsOnly
              draftBinding={id === draftId ? draftBinding : undefined}
              disabled={!!busy && editingId !== id}
              onRecordingChange={(recording) =>
                setEditingId(recording ? id : null)
              }
            />
            {id === "transcribe" && (
              <ResetButton
                onClick={() => resetBinding(id)}
                ariaLabel={t("settings.general.shortcut.reset")}
                disabled={!!busy || isUpdating(`binding_${id}`)}
              />
            )}
            {additionalIds.includes(id) && (
              <button
                type="button"
                onClick={() => remove(id)}
                aria-label={t("settings.general.shortcut.remove")}
                disabled={!!busy || isUpdating(`binding_${id}`)}
                className="p-1 rounded-md hover:bg-logo-primary/10 disabled:opacity-50"
              >
                <X className="w-4 h-4" />
              </button>
            )}
          </div>
        ))}
      </div>
    </SettingContainer>
  );
};

import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { useSettings } from "@/hooks/useSettings";
import { Input } from "../ui/Input";
import { Button } from "../ui/Button";
import { SettingContainer } from "../ui/SettingContainer";
import {
  getCustomWordValidationError,
  normalizeCustomWord,
} from "@/utils/customWord";

interface CustomWordsProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

export const CustomWords: React.FC<CustomWordsProps> = React.memo(
  ({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const { getSetting, updateCustomWords, isUpdating } = useSettings();
    const [newWord, setNewWord] = useState("");
    const [error, setError] = useState<string | null>(null);
    const customWords = getSetting("custom_words") || [];
    const normalizedWord = normalizeCustomWord(newWord);
    const validationError = getCustomWordValidationError(newWord);
    const visibleError = error ?? validationError;

    const handleAddWord = async () => {
      if (validationError) {
        setError(validationError);
        return;
      }
      if (normalizedWord) {
        if (customWords.includes(normalizedWord)) {
          setError("duplicate");
          return;
        }
        setError(null);
        try {
          await updateCustomWords([...customWords, normalizedWord]);
          setNewWord("");
        } catch {
          setError("updateFailed");
        }
      }
    };

    const handleRemoveWord = async (wordToRemove: string) => {
      setError(null);
      try {
        await updateCustomWords(
          customWords.filter((word) => word !== wordToRemove),
        );
      } catch {
        setError("updateFailed");
      }
    };

    const handleKeyPress = (e: React.KeyboardEvent) => {
      if (e.key === "Enter") {
        e.preventDefault();
        void handleAddWord();
      }
    };

    return (
      <>
        <SettingContainer
          title={t("settings.advanced.customWords.title")}
          description={t("settings.advanced.customWords.description")}
          descriptionMode={descriptionMode}
          grouped={grouped}
        >
          <div className="flex items-center gap-2">
            <Input
              type="text"
              className="max-w-40"
              value={newWord}
              onChange={(e) => {
                setNewWord(e.target.value);
                setError(null);
              }}
              onKeyDown={handleKeyPress}
              placeholder={t("settings.advanced.customWords.placeholder")}
              variant="compact"
              disabled={isUpdating("custom_words")}
            />
            <Button
              onClick={handleAddWord}
              disabled={!normalizedWord || isUpdating("custom_words")}
              variant="primary"
              size="md"
            >
              {t("settings.advanced.customWords.add")}
            </Button>
          </div>
        </SettingContainer>
        {visibleError && (
          <p role="alert" className="px-4 text-sm text-red-500">
            {visibleError === "duplicate"
              ? t("settings.advanced.customWords.duplicate", {
                  word: normalizedWord,
                })
              : t(`settings.advanced.customWords.${visibleError}`)}
          </p>
        )}
        {customWords.length > 0 && (
          <div
            className={`px-4 p-2 ${grouped ? "" : "rounded-lg border border-mid-gray/20"} flex flex-wrap gap-1`}
          >
            {customWords.map((word) => (
              <Button
                key={word}
                onClick={() => handleRemoveWord(word)}
                disabled={isUpdating("custom_words")}
                variant="secondary"
                size="sm"
                className="inline-flex items-center gap-1 cursor-pointer"
                aria-label={t("settings.advanced.customWords.remove", { word })}
              >
                <span>{word}</span>
                <svg
                  className="w-3 h-3"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    strokeWidth={2}
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </Button>
            ))}
          </div>
        )}
      </>
    );
  },
);

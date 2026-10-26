import React, { useState } from "react";
import { BookA, Plus, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useSettings } from "@/hooks/useSettings";
import { Input } from "../ui/Input";
import { Button } from "../ui/Button";
import {
  getCustomWordValidationError,
  normalizeCustomWord,
} from "@/utils/customWord";

export const CustomWords: React.FC = React.memo(() => {
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
    <section
      className="settings-card dictionary-panel"
      aria-labelledby="dictionary-words-title"
    >
      <div className="dictionary-intro">
        <span className="dictionary-icon" aria-hidden="true">
          <BookA size={22} strokeWidth={1.8} />
        </span>
        <div className="flex items-center gap-2">
          <h2 id="dictionary-words-title" className="text-lg font-semibold">
            {t("settings.advanced.customWords.title")}
          </h2>
          {customWords.length > 0 && (
            <span className="dictionary-count" aria-hidden="true">
              {customWords.length}
            </span>
          )}
        </div>
        <p className="dictionary-description">
          {t("settings.advanced.customWords.description")}
        </p>
      </div>
      <div className="dictionary-editor">
        <div className="dictionary-entry">
          <Input
            type="text"
            aria-label={t("settings.advanced.customWords.placeholder")}
            className="dictionary-input"
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
            className="dictionary-add"
          >
            <Plus className="size-4" aria-hidden="true" />
            {t("settings.advanced.customWords.add")}
          </Button>
        </div>
        {visibleError && (
          <p role="alert" className="text-sm text-error">
            {visibleError === "duplicate"
              ? t("settings.advanced.customWords.duplicate", {
                  word: normalizedWord,
                })
              : t(`settings.advanced.customWords.${visibleError}`)}
          </p>
        )}
        {customWords.length > 0 && (
          <div className="dictionary-words">
            {customWords.map((word) => (
              <Button
                key={word}
                onClick={() => handleRemoveWord(word)}
                disabled={isUpdating("custom_words")}
                variant="secondary"
                size="sm"
                className="dictionary-word"
                aria-label={t("settings.advanced.customWords.remove", { word })}
              >
                <span>{word}</span>
                <X className="size-3.5 opacity-60" aria-hidden="true" />
              </Button>
            ))}
          </div>
        )}
      </div>
    </section>
  );
});

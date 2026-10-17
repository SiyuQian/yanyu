export const normalizeCustomWord = (word: string) =>
  word
    .replace(/[<>"']/g, "")
    .replace(/\s+/g, " ")
    .trim();

export const getCustomWordValidationError = (word: string) => {
  const normalized = normalizeCustomWord(word);
  if (word.length > 0 && !normalized) return "invalid";
  if (normalized.length > 50) return "tooLong";
  return null;
};

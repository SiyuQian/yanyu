#if DEBUG
  import Foundation

  /// Measures character error rate across languages without requiring word tokenization.
  /// Comparison ignores whitespace and letter case while preserving punctuation.
  enum TranscriptionCharacterError {
    struct Result: Equatable {
      let editCount: Int
      let referenceCharacterCount: Int

      var rate: Double {
        Double(editCount) / Double(referenceCharacterCount)
      }
    }

    static func measure(reference: String, hypothesis: String) -> Result? {
      let referenceCharacters = comparableCharacters(in: reference)
      guard !referenceCharacters.isEmpty else {
        return nil
      }
      let hypothesisCharacters = comparableCharacters(in: hypothesis)

      var previousRow = Array(0...hypothesisCharacters.count)
      for (referenceIndex, referenceCharacter) in referenceCharacters.enumerated() {
        var currentRow = Array(repeating: 0, count: hypothesisCharacters.count + 1)
        currentRow[0] = referenceIndex + 1

        for (hypothesisIndex, hypothesisCharacter) in hypothesisCharacters.enumerated() {
          let substitutionCost = referenceCharacter == hypothesisCharacter ? 0 : 1
          currentRow[hypothesisIndex + 1] = min(
            previousRow[hypothesisIndex + 1] + 1,
            currentRow[hypothesisIndex] + 1,
            previousRow[hypothesisIndex] + substitutionCost
          )
        }
        previousRow = currentRow
      }

      return Result(
        editCount: previousRow[hypothesisCharacters.count],
        referenceCharacterCount: referenceCharacters.count
      )
    }

    private static func comparableCharacters(in text: String) -> [Character] {
      text
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .filter { !$0.isWhitespace }
    }
  }
#endif

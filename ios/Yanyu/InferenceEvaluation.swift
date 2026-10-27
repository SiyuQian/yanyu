#if DEBUG
  import Foundation

  struct InferenceEvaluation: Equatable {
    let audioFileName: String
    let audioFileSizeBytes: Int64
    let audioSHA256: String?
    let modelName: String
    let modelFileSizeBytes: Int64?
    let modelSHA256: String?
    let languageIntent: String
    let resolvedLanguage: String
    let deviceIdentifier: String
    let operatingSystemVersion: String
    let audioDurationMs: UInt64
    let processingDurationMs: UInt64
    let transcript: String
    let referenceText: String
    let peakSampledMemoryFootprintBytes: UInt64?
    let thermalStates: [String]
    let memorySampleIntervalMs: UInt64
    let evaluatedAt = Date.now

    var realTimeFactor: Double? {
      guard audioDurationMs > 0 else {
        return nil
      }
      return Double(processingDurationMs) / Double(audioDurationMs)
    }

    var characterError: TranscriptionCharacterError.Result? {
      TranscriptionCharacterError.measure(reference: referenceText, hypothesis: transcript)
    }

    var report: String {
      let formattedRealTimeFactor =
        realTimeFactor.map {
          String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
        } ?? "n/a"
      let formattedModelSize = modelFileSizeBytes.map(String.init) ?? "unknown"
      let formattedMemory =
        peakSampledMemoryFootprintBytes.map(String.init) ?? "unavailable"
      let formattedThermalStates =
        thermalStates.isEmpty
        ? "unavailable"
        : thermalStates.joined(
          separator: " -> "
        )
      let formattedCharacterError =
        characterError.map {
          let percentage = String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            $0.rate * 100
          )
          return "\(percentage)% (\($0.editCount)/\($0.referenceCharacterCount))"
        } ?? "n/a"

      return """
        Yanyu iOS inference evaluation
        Evaluated at: \(ISO8601DateFormatter().string(from: evaluatedAt))
        Device: \(deviceIdentifier)
        OS: \(operatingSystemVersion)
        Model: \(modelName) (\(formattedModelSize) bytes)
        Model SHA-256: \(modelSHA256 ?? "unavailable")
        Language intent: \(languageIntent)
        Language sent to model: \(resolvedLanguage)
        Audio fixture: \(audioFileName) (\(audioFileSizeBytes) bytes)
        Audio SHA-256: \(audioSHA256 ?? "unavailable")
        Audio duration: \(audioDurationMs) ms
        Core processing duration: \(processingDurationMs) ms
        Real-time factor: \(formattedRealTimeFactor)
        Peak sampled physical memory footprint: \(formattedMemory) bytes
        Memory sampling interval: \(memorySampleIntervalMs) ms
        Thermal states observed: \(formattedThermalStates)
        Character error rate (CER; case-insensitive, ignores spaces, keeps punctuation): \(formattedCharacterError)

        Reference text:
        \(referenceText.isEmpty ? "unavailable" : referenceText)

        Transcript:
        \(transcript)
        """
    }

    static func sha256(at url: URL) async -> String? {
      let path = url.path
      return await Task.detached(priority: .utility) {
        try? computeFileSha256(path: path)
      }.value
    }
  }
#endif

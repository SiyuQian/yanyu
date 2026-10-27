import Foundation

struct TranscriptionOutcome {
  let text: String
  let detectedLanguage: String?
  let audioDurationMs: UInt64
  let processingDurationMs: UInt64
}

enum TranscriptionProgress: Equatable, Sendable {
  case preparingAudio
  case recognizing
}

enum TranscriptionEngineError: Error {
  case modelNotLoaded
  case cancelled(partialText: String?)
  case incompleteOutput(kind: IncompleteOutputKind, partialText: String?)
  case inputTooLong
}

@MainActor
protocol TranscriptionEngine {
  func loadModel(at modelURL: URL) async throws
  func transcribe(
    fileAt audioURL: URL,
    language: String?,
    progress: @escaping @MainActor (TranscriptionProgress) -> Void
  ) async throws -> TranscriptionOutcome
  func cancel()
}

@MainActor
final class YanyuCoreService: TranscriptionEngine {
  private var transcriber: Transcriber?

  func loadModel(at modelURL: URL) async throws {
    let modelPath = modelURL.path
    let loadedTranscriber = try await Task.detached(priority: .userInitiated) {
      try Transcriber.loadModel(modelPath: modelPath)
    }.value
    transcriber = loadedTranscriber
  }

  func transcribe(
    fileAt audioURL: URL,
    language: String?,
    progress: @escaping @MainActor (TranscriptionProgress) -> Void
  ) async throws -> TranscriptionOutcome {
    guard let transcriber else {
      throw TranscriptionEngineError.modelNotLoaded
    }
    let audioPath = audioURL.path
    progress(.preparingAudio)
    let progressTask = Task { @MainActor in
      var lastProgress: TranscriptionProgress? = .preparingAudio
      while !Task.isCancelled {
        let currentProgress: TranscriptionProgress?
        switch transcriber.currentStage() {
        case .idle:
          currentProgress = nil
        case .preparingAudio:
          currentProgress = .preparingAudio
        case .recognizing:
          currentProgress = .recognizing
        }
        if let currentProgress, currentProgress != lastProgress {
          lastProgress = currentProgress
          progress(currentProgress)
        }
        do {
          try await Task.sleep(for: .milliseconds(50))
        } catch {
          return
        }
      }
    }
    defer { progressTask.cancel() }
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try transcriber.transcribeFile(audioPath: audioPath, language: language)
      }.value
      return TranscriptionOutcome(
        text: result.text,
        detectedLanguage: result.detectedLanguage,
        audioDurationMs: result.audioDurationMs,
        processingDurationMs: result.processingDurationMs
      )
    } catch CoreError.Cancelled(let partialText) {
      throw TranscriptionEngineError.cancelled(partialText: partialText)
    } catch CoreError.IncompleteOutput(let kind, let partialText) {
      throw TranscriptionEngineError.incompleteOutput(kind: kind, partialText: partialText)
    } catch CoreError.InputTooLong {
      throw TranscriptionEngineError.inputTooLong
    }
  }

  func cancel() {
    transcriber?.cancel()
  }
}

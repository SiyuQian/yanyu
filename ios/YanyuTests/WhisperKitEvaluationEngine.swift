import AVFoundation
import Foundation
import WhisperKit

@testable import Yanyu

@MainActor
final class WhisperKitEvaluationEngine: TranscriptionEngine {
  private var whisperKit: WhisperKit?
  private let cancellationState = WhisperKitEvaluationCancellationState()

  func loadModel(at modelURL: URL) async throws {
    let tokenizerFolder = modelURL.appendingPathComponent("tokenizer", isDirectory: true)
    try FileManager.default.createDirectory(
      at: tokenizerFolder,
      withIntermediateDirectories: true
    )
    let config = WhisperKitConfig(
      model: "small",
      modelFolder: modelURL.path,
      tokenizerFolder: tokenizerFolder,
      verbose: false,
      load: true,
      download: false
    )
    whisperKit = try await WhisperKit(config)
  }

  func transcribe(
    fileAt audioURL: URL,
    language: String?,
    progress: @escaping @MainActor (Yanyu.TranscriptionProgress) -> Void
  ) async throws -> TranscriptionOutcome {
    guard let whisperKit else {
      throw TranscriptionEngineError.modelNotLoaded
    }

    cancellationState.reset()
    progress(.preparingAudio)
    let audioFile = try AVAudioFile(forReading: audioURL)
    let sampleRate = audioFile.processingFormat.sampleRate
    guard sampleRate > 0 else {
      throw NSError(
        domain: "WhisperKitEvaluationEngine",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Audio sample rate is invalid."]
      )
    }
    let audioDurationMs = UInt64((Double(audioFile.length) / sampleRate * 1_000).rounded())
    progress(.recognizing)

    let startTime = DispatchTime.now().uptimeNanoseconds
    let cancellationState = self.cancellationState
    let decodingOptions: DecodingOptions
    if let language {
      decodingOptions = DecodingOptions(language: language)
    } else {
      decodingOptions = DecodingOptions(
        usePrefillPrompt: false,
        detectLanguage: true
      )
    }
    let results = try await whisperKit.transcribe(
      audioPath: audioURL.path,
      decodeOptions: decodingOptions,
      callback: { _ in !cancellationState.isCancelled }
    )
    let processingDurationMs = (DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
    let transcript = results.map(\.text).joined(separator: " ")

    if cancellationState.isCancelled {
      throw TranscriptionEngineError.cancelled(partialText: transcript.isEmpty ? nil : transcript)
    }

    return TranscriptionOutcome(
      text: transcript,
      detectedLanguage: results.first?.language,
      audioDurationMs: audioDurationMs,
      processingDurationMs: processingDurationMs
    )
  }

  func cancel() {
    cancellationState.cancel()
  }
}

private final class WhisperKitEvaluationCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = false
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
  }
}

import XCTest

@testable import Yanyu

final class InferenceEvaluationTests: XCTestCase {
  func testCharacterErrorUsesCaseInsensitiveNonWhitespaceGraphemes() {
    let result = TranscriptionCharacterError.measure(
      reference: "Hello, WORLD!",
      hypothesis: "hello world"
    )

    XCTAssertEqual(result?.editCount, 2)
    XCTAssertEqual(result?.referenceCharacterCount, 12)
    XCTAssertEqual(result?.rate ?? -1, 2.0 / 12.0, accuracy: 0.000_001)
  }

  func testCharacterErrorSupportsChineseAndMixedLanguageText() {
    let result = TranscriptionCharacterError.measure(
      reference: "你好, world!",
      hypothesis: "你好 world"
    )

    XCTAssertEqual(result?.editCount, 2)
    XCTAssertEqual(result?.referenceCharacterCount, 9)
    XCTAssertEqual(result?.rate ?? -1, 2.0 / 9.0, accuracy: 0.000_001)
  }

  func testCharacterErrorIsUnavailableForEmptyReference() {
    XCTAssertNil(TranscriptionCharacterError.measure(reference: " \n", hypothesis: "text"))
  }

  @MainActor
  func testDeviceResourceMonitorCapturesCurrentProcessAndThermalState() {
    let monitor = DeviceResourceMonitor()
    monitor.start()
    let measurement = monitor.stop()

    XCTAssertGreaterThan(measurement.peakSampledMemoryFootprintBytes ?? 0, 0)
    XCTAssertFalse(measurement.thermalStates.isEmpty)
    XCTAssertEqual(measurement.sampleIntervalMs, 100)
    XCTAssertEqual(monitor.stop(), measurement)
  }

  func testReportIncludesDeviceModelAndRealtimeFactor() {
    let evaluation = InferenceEvaluation(
      audioFileName: "english-fixture.wav",
      audioFileSizeBytes: 1_024,
      audioSHA256: "audio-hash",
      modelName: "candidate.gguf",
      modelFileSizeBytes: 2_048,
      modelSHA256: "model-hash",
      languageIntent: "auto",
      resolvedLanguage: "auto",
      deviceIdentifier: "iPhone17,3",
      operatingSystemVersion: "iOS 27.0",
      audioDurationMs: 10_000,
      processingDurationMs: 5_000,
      transcript: "Hello world",
      referenceText: "Hello, WORLD!",
      peakSampledMemoryFootprintBytes: 3_145_728,
      thermalStates: ["nominal", "fair"],
      memorySampleIntervalMs: 100
    )

    XCTAssertEqual(evaluation.realTimeFactor, 0.5)
    XCTAssertTrue(evaluation.report.contains("iPhone17,3"))
    XCTAssertTrue(evaluation.report.contains("0.500"))
    XCTAssertTrue(evaluation.report.contains("english-fixture.wav"))
    XCTAssertTrue(evaluation.report.contains("2048 bytes"))
    XCTAssertTrue(evaluation.report.contains("Audio SHA-256: audio-hash"))
    XCTAssertTrue(evaluation.report.contains("Model SHA-256: model-hash"))
    XCTAssertTrue(evaluation.report.contains("Language intent: auto"))
    XCTAssertTrue(evaluation.report.contains("Hello world"))
    XCTAssertTrue(
      evaluation.report.contains("Peak sampled physical memory footprint: 3145728 bytes"))
    XCTAssertTrue(evaluation.report.contains("Memory sampling interval: 100 ms"))
    XCTAssertTrue(evaluation.report.contains("Thermal states observed: nominal -> fair"))
    XCTAssertTrue(
      evaluation.report.contains(
        "Character error rate (CER; case-insensitive, ignores spaces, keeps punctuation): 16.7% (2/12)"
      )
    )
    XCTAssertTrue(evaluation.report.contains("Reference text:\nHello, WORLD!"))
  }

  func testRealtimeFactorIsUnavailableForEmptyAudio() {
    let evaluation = InferenceEvaluation(
      audioFileName: "empty.wav",
      audioFileSizeBytes: 44,
      audioSHA256: nil,
      modelName: "candidate.gguf",
      modelFileSizeBytes: nil,
      modelSHA256: nil,
      languageIntent: "auto",
      resolvedLanguage: "en",
      deviceIdentifier: "iPhone17,3",
      operatingSystemVersion: "iOS 27.0",
      audioDurationMs: 0,
      processingDurationMs: 250,
      transcript: "",
      referenceText: "",
      peakSampledMemoryFootprintBytes: nil,
      thermalStates: [],
      memorySampleIntervalMs: 100
    )

    XCTAssertNil(evaluation.realTimeFactor)
    XCTAssertTrue(evaluation.report.contains("n/a"))
    XCTAssertTrue(evaluation.report.contains("Audio SHA-256: unavailable"))
  }

  func testSHA256HashesAFileWithoutLoadingItAllIntoMemory() async throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: fileURL)
    }
    try Data("hello".utf8).write(to: fileURL)

    let hash = await InferenceEvaluation.sha256(at: fileURL)

    XCTAssertEqual(hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }
}

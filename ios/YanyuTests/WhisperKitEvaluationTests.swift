import Foundation
import XCTest

@testable import Yanyu

@MainActor
final class WhisperKitEvaluationTests: XCTestCase {
  func testCoreMLCandidateAgainstFleursFixtures() async throws {
    let documentsDirectory = try XCTUnwrap(
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    )
    let evaluationDirectory = documentsDirectory.appendingPathComponent(
      "whisperkit-evaluation",
      isDirectory: true
    )
    let modelURL = evaluationDirectory.appendingPathComponent(
      "openai_whisper-small", isDirectory: true)
    guard
      FileManager.default.fileExists(
        atPath: evaluationDirectory.appendingPathComponent("manifest.json").path
      ),
      FileManager.default.fileExists(atPath: modelURL.path)
    else {
      throw XCTSkip(
        "Stage the WhisperKit small model and FLEURS manifest in Documents/whisperkit-evaluation.")
    }

    let manifest = try FleursEvaluationManifest.load(from: evaluationDirectory)
    try await manifest.verifyAudioFiles(in: evaluationDirectory)
    let fixtures = manifest.samples
    XCTAssertEqual(fixtures.count, 16)
    XCTAssertEqual(fixtures.filter { $0.language == "zh" }.count, 8)
    XCTAssertEqual(fixtures.filter { $0.language == "en" }.count, 8)

    let engine = WhisperKitEvaluationEngine()
    let resourceMonitor = DeviceResourceMonitor()
    resourceMonitor.start()
    let modelLoadStart = DispatchTime.now().uptimeNanoseconds
    try await engine.loadModel(at: modelURL)
    let modelLoadDurationMs =
      (DispatchTime.now().uptimeNanoseconds - modelLoadStart) / 1_000_000

    var measurements: [FixtureMeasurement] = []
    for fixture in fixtures {
      let audioURL = evaluationDirectory.appendingPathComponent(fixture.filename)
      let outcome = try await engine.transcribe(fileAt: audioURL, language: nil) { _ in }
      let characterError = try XCTUnwrap(
        TranscriptionCharacterError.measure(
          reference: fixture.reference,
          hypothesis: outcome.text
        ),
        fixture.filename
      )
      XCTAssertGreaterThan(outcome.audioDurationMs, 0, fixture.filename)
      XCTAssertGreaterThan(outcome.processingDurationMs, 0, fixture.filename)
      print(
        "\(fixture.filename): language=\(outcome.detectedLanguage ?? "unknown"), CER=\(String(format: "%.1f", 100 * characterError.rate))%, transcript=\(outcome.text)"
      )
      measurements.append(
        FixtureMeasurement(
          language: fixture.language,
          detectedLanguage: outcome.detectedLanguage,
          audioDurationMs: outcome.audioDurationMs,
          processingDurationMs: outcome.processingDurationMs,
          editCount: characterError.editCount,
          referenceCharacterCount: characterError.referenceCharacterCount
        )
      )
    }

    let resourceMeasurement = resourceMonitor.stop()
    let modelSizeBytes = Self.directorySize(at: modelURL)
    print("Model load: \(modelLoadDurationMs) ms; files: \(modelSizeBytes) bytes")
    print(
      "Peak sampled memory: \(resourceMeasurement.peakSampledMemoryFootprintBytes.map(String.init) ?? "unavailable") bytes; thermal: \(resourceMeasurement.thermalStates.joined(separator: " -> "))"
    )
    print("WhisperKit openai_whisper-small, FLEURS dev subset, automatic language detection")
    for language in ["zh", "en"] {
      let languageMeasurements = measurements.filter { $0.language == language }
      let editCount = languageMeasurements.reduce(0) { $0 + $1.editCount }
      let referenceCharacterCount = languageMeasurements.reduce(0) {
        $0 + $1.referenceCharacterCount
      }
      let correctLanguageCount = languageMeasurements.filter {
        Self.canonicalLanguage($0.detectedLanguage) == language
      }.count
      let medianProcessingMs = Self.median(languageMeasurements.map(\.processingDurationMs))
      let medianAudioMs = Self.median(languageMeasurements.map(\.audioDurationMs))
      let realTimeFactor = Double(medianProcessingMs) / Double(medianAudioMs)
      print(
        "\(language): CER \(String(format: "%.1f", 100 * Double(editCount) / Double(referenceCharacterCount)))% (\(editCount)/\(referenceCharacterCount)); language \(correctLanguageCount)/\(languageMeasurements.count); median RTF \(String(format: "%.3f", realTimeFactor))"
      )
    }
  }

  func testForcedLanguageCandidateSmokeSamples() async throws {
    let documentsDirectory = try XCTUnwrap(
      FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    )
    let evaluationDirectory = documentsDirectory.appendingPathComponent(
      "whisperkit-evaluation",
      isDirectory: true
    )
    let modelURL = evaluationDirectory.appendingPathComponent(
      "openai_whisper-small", isDirectory: true)
    guard
      FileManager.default.fileExists(
        atPath: evaluationDirectory.appendingPathComponent("manifest.json").path
      ),
      FileManager.default.fileExists(atPath: modelURL.path)
    else {
      throw XCTSkip("Stage the WhisperKit small model and FLEURS manifest for this smoke test.")
    }
    let manifest = try FleursEvaluationManifest.load(from: evaluationDirectory)
    try await manifest.verifyAudioFiles(in: evaluationDirectory)
    let fixtures = manifest.samples
    let selectedFixtures = fixtures.filter {
      ["zh_01.wav", "zh_02.wav", "en_01.wav", "en_02.wav"].contains($0.filename)
    }
    let engine = WhisperKitEvaluationEngine()
    try await engine.loadModel(at: modelURL)
    for fixture in selectedFixtures {
      let audioURL = evaluationDirectory.appendingPathComponent(fixture.filename)
      let outcome = try await engine.transcribe(fileAt: audioURL, language: fixture.language) { _ in
      }
      let characterError = try XCTUnwrap(
        TranscriptionCharacterError.measure(reference: fixture.reference, hypothesis: outcome.text)
      )
      print(
        "forced \(fixture.language) \(fixture.filename): detected=\(outcome.detectedLanguage ?? "unknown"), CER=\(String(format: "%.1f", 100 * characterError.rate))%, transcript=\(outcome.text)"
      )
    }
  }

  private static func canonicalLanguage(_ language: String?) -> String? {
    switch language?.lowercased() {
    case "zh", "chinese": return "zh"
    case "en", "english": return "en"
    default: return language?.lowercased()
    }
  }

  private static func median(_ values: [UInt64]) -> UInt64 {
    let sortedValues = values.sorted()
    guard !sortedValues.isEmpty else { return 0 }
    let middleIndex = sortedValues.count / 2
    if sortedValues.count.isMultiple(of: 2) {
      return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2
    }
    return sortedValues[middleIndex]
  }

  private static func directorySize(at directoryURL: URL) -> UInt64 {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }
    var size: UInt64 = 0
    for case let fileURL as URL in enumerator {
      let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
      size += UInt64(fileSize ?? 0)
    }
    return size
  }
}

private struct FixtureMeasurement {
  let language: String
  let detectedLanguage: String?
  let audioDurationMs: UInt64
  let processingDurationMs: UInt64
  let editCount: Int
  let referenceCharacterCount: Int
}

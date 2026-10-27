import Foundation
import XCTest

@testable import Yanyu

final class FleursEvaluationManifestTests: XCTestCase {
  func testLoadsPinnedManifestAndVerifiesAudioHash() async throws {
    let directory = try makeEvaluationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("zh_01.wav")
    try Data("evaluation audio".utf8).write(to: audioURL)
    let digest = try computeFileSha256(path: audioURL.path)
    try writeManifest(
      in: directory, revision: FleursEvaluationManifest.pinnedRevision, sha256: digest)

    let manifest = try FleursEvaluationManifest.load(from: directory)
    try await manifest.verifyAudioFiles(in: directory)

    XCTAssertEqual(manifest.dataset, "google/fleurs")
    XCTAssertEqual(manifest.samples.first?.reference, "你好")
  }

  func testRejectsChangedAudioHash() async throws {
    let directory = try makeEvaluationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("evaluation audio".utf8).write(
      to: directory.appendingPathComponent("zh_01.wav")
    )
    try writeManifest(
      in: directory,
      revision: FleursEvaluationManifest.pinnedRevision,
      sha256: String(repeating: "0", count: 64)
    )
    let manifest = try FleursEvaluationManifest.load(from: directory)

    do {
      try await manifest.verifyAudioFiles(in: directory)
      XCTFail("Expected an audio hash mismatch.")
    } catch let error as FleursEvaluationManifestError {
      XCTAssertEqual(error, .hashMismatch("zh_01.wav"))
    }
  }

  func testRejectsUnpinnedDatasetRevision() throws {
    let directory = try makeEvaluationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeManifest(in: directory, revision: "main", sha256: String(repeating: "a", count: 64))

    XCTAssertThrowsError(try FleursEvaluationManifest.load(from: directory)) { error in
      XCTAssertEqual(error as? FleursEvaluationManifestError, .invalidMetadata)
    }
  }

  func testRejectsLegacyArrayManifestAsInvalidMetadata() throws {
    let directory = try makeEvaluationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("[]".utf8).write(to: directory.appendingPathComponent("manifest.json"))

    XCTAssertThrowsError(try FleursEvaluationManifest.load(from: directory)) { error in
      XCTAssertEqual(error as? FleursEvaluationManifestError, .invalidMetadata)
    }
  }

  func testRejectsAudioPathTraversal() throws {
    let directory = try makeEvaluationDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeManifest(
      in: directory,
      revision: FleursEvaluationManifest.pinnedRevision,
      filename: "../outside.wav"
    )

    XCTAssertThrowsError(try FleursEvaluationManifest.load(from: directory)) { error in
      XCTAssertEqual(error as? FleursEvaluationManifestError, .invalidSample("../outside.wav"))
    }
  }

  private func makeEvaluationDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeManifest(
    in directory: URL,
    revision: String,
    filename: String = "zh_01.wav",
    sha256: String = String(repeating: "a", count: 64)
  ) throws {
    let manifest: [String: Any] = [
      "dataset": "google/fleurs",
      "revision": revision,
      "license": "CC-BY-4.0",
      "selection": "one fixture for unit testing",
      "samples": [
        [
          "language": "zh",
          "filename": filename,
          "source_filename": "public-source.wav",
          "reference": "你好",
          "duration_ms": 1000,
          "categories": ["short"],
          "sha256": sha256,
        ]
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("manifest.json"))
  }
}

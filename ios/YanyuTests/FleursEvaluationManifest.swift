import Foundation
import Yanyu

enum FleursEvaluationManifestError: Error, Equatable {
  case invalidMetadata
  case invalidSample(String)
  case missingAudio(String)
  case hashMismatch(String)
}

struct FleursEvaluationManifest: Decodable {
  static let pinnedRevision = "d7c758a6dceecd54a98cac43404d3d576e721f07"

  let dataset: String
  let revision: String
  let license: String
  let selection: String
  let samples: [FleursEvaluationSample]

  static func load(from directory: URL) throws -> FleursEvaluationManifest {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = try Data(contentsOf: manifestURL)
    let manifest: FleursEvaluationManifest
    do {
      manifest = try decoder.decode(FleursEvaluationManifest.self, from: data)
    } catch is DecodingError {
      throw FleursEvaluationManifestError.invalidMetadata
    }
    guard
      manifest.dataset == "google/fleurs",
      manifest.revision == pinnedRevision,
      manifest.license == "CC-BY-4.0",
      !manifest.selection.isEmpty,
      !manifest.samples.isEmpty
    else {
      throw FleursEvaluationManifestError.invalidMetadata
    }

    var filenames = Set<String>()
    for sample in manifest.samples {
      let isSafeFilename =
        !sample.filename.isEmpty
        && URL(fileURLWithPath: sample.filename).lastPathComponent == sample.filename
        && sample.filename.hasSuffix(".wav")
        && !sample.sourceFilename.isEmpty
        && URL(fileURLWithPath: sample.sourceFilename).lastPathComponent == sample.sourceFilename
        && sample.sourceFilename.hasSuffix(".wav")
      let hasValidDigest =
        sample.sha256.count == 64
        && sample.sha256.allSatisfy { $0.isHexDigit }
      guard
        isSafeFilename,
        hasValidDigest,
        sample.durationMs > 0,
        !sample.reference.isEmpty,
        !sample.categories.isEmpty,
        ["zh", "en"].contains(sample.language),
        filenames.insert(sample.filename).inserted
      else {
        throw FleursEvaluationManifestError.invalidSample(sample.filename)
      }
    }
    return manifest
  }

  func verifyAudioFiles(in directory: URL) async throws {
    for sample in samples {
      let audioURL = directory.appendingPathComponent(sample.filename)
      guard FileManager.default.fileExists(atPath: audioURL.path) else {
        throw FleursEvaluationManifestError.missingAudio(sample.filename)
      }
      let digest = try await Task.detached(priority: .utility) {
        try computeFileSha256(path: audioURL.path)
      }.value
      guard digest.caseInsensitiveCompare(sample.sha256) == .orderedSame else {
        throw FleursEvaluationManifestError.hashMismatch(sample.filename)
      }
    }
  }
}

struct FleursEvaluationSample: Decodable {
  let language: String
  let filename: String
  let sourceFilename: String
  let reference: String
  let durationMs: Int
  let categories: [String]
  let sha256: String
}

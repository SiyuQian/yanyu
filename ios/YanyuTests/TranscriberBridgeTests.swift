import Darwin
import Foundation
import XCTest

@testable import Yanyu

final class TranscriberBridgeTests: XCTestCase {
  func testModelLoadFailureCrossesRustBridgeAsTypedError() {
    XCTAssertThrowsError(
      try Transcriber.loadModel(modelPath: "/tmp/yanyu-missing-model.gguf")
    ) { error in
      guard case CoreError.ModelLoad = error else {
        return XCTFail("Expected a typed Rust model-load error, got \(error)")
      }
    }
  }

  func testInvalidGGUFProbeCrossesRustBridgeAsUnsupported() throws {
    let modelURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).gguf")
    defer {
      try? FileManager.default.removeItem(at: modelURL)
    }
    try Data("not a GGUF model".utf8).write(to: modelURL)

    let probe = probeModelFile(path: modelURL.path)

    XCTAssertEqual(probe.verdict, .unsupported)
  }

  func testTranscriptNormalizationCrossesRustBridge() {
    XCTAssertEqual(
      normalizeTranscriptionOutput(text: "  I I I I think this works  "),
      "I think this works"
    )
  }

  func testBundledModelCatalogCrossesRustBridgeWithPinnedArtifactMetadata() throws {
    let catalog = bundledModelCatalog()
    XCTAssertFalse(catalog.isEmpty)

    let qwen = try XCTUnwrap(catalog.first { $0.name == "Qwen3-ASR 0.6B" })
    XCTAssertEqual(qwen.defaultQuant, "Q8_0")
    XCTAssertEqual(qwen.recommendedRank, 9)
    XCTAssertEqual(
      qwen.files.first { $0.filename == "Qwen3-ASR-0.6B-Q4_K_M.gguf" }?.sha256,
      "5b58f32a58ffa2c8783e0b0963485623e286e6272d953dfc9e28bc3447dee0c0"
    )
    guard case .huggingFace(let repoID, let revision) = qwen.source else {
      return XCTFail("Expected the catalog model to expose its pinned Hub source")
    }
    XCTAssertEqual(repoID, "handy-computer/Qwen3-ASR-0.6B-gguf")
    XCTAssertEqual(revision, "e4e16599b900eb0cb36e524514756bb92eb092b7")

    func model(id: String, recommended: Bool) -> ModelInfo {
      ModelInfo(
        id: id,
        name: id,
        description: "",
        filename: "",
        source: .local,
        sizeMb: 0,
        isDownloaded: true,
        isDownloading: false,
        partialSize: 0,
        isDirectory: false,
        engineType: .transcribeCpp,
        accuracyScore: 0,
        speedScore: 0,
        supportsTranslation: false,
        isRecommended: recommended,
        supportedLanguages: [],
        supportsLanguageSelection: false,
        isCustom: false,
        supportsStreaming: false,
        supportsLanguageDetection: false
      )
    }
    let sortedModels = sortModelsByCatalogRank(
      models: [model(id: "unranked", recommended: true), model(id: qwen.id, recommended: false)],
      catalog: catalog
    )
    XCTAssertEqual(sortedModels.map(\.id), [qwen.id, "unranked"])
  }

  func testTranscriptTextCleanupCrossesRustBridge() {
    XCTAssertEqual(
      correctTranscriptionCustomWords(
        text: "I use chat g p, daily.",
        customWords: ["ChatGPT"],
        threshold: 0.5
      ),
      "I use ChatGPT, daily."
    )
    XCTAssertEqual(
      normalizeTranscriptionOutput(
        text: cleanTranscriptionFillers(
          text: "um I think this works; uh, yes",
          languageCode: nil,
          customFillerWords: nil,
          enabled: true
        )
      ),
      "um I think this works; yes"
    )
    XCTAssertEqual(
      normalizeTranscriptionOutput(
        text: cleanTranscriptionFillers(
          text: "um I think this works; uh, yes",
          languageCode: "en",
          customFillerWords: nil,
          enabled: true
        )
      ),
      "I think this works; yes"
    )
    XCTAssertEqual(
      normalizeTranscriptionOutput(
        text: cleanTranscriptionFillers(
          text: "um customword I think",
          languageCode: nil,
          customFillerWords: ["customword"],
          enabled: true
        )
      ),
      "um I think"
    )
  }

  func testCombinedTranscriptPostProcessingCrossesRustBridge() {
    let options = TranscriptPostProcessingOptions(
      customWords: ["ChatGPT"],
      correctionThreshold: 0.5,
      languageCode: "en",
      customFillerWords: nil,
      fillerRemovalEnabled: true
    )

    XCTAssertEqual(
      postProcessTranscription(text: "I use chat g p, um daily.", options: options),
      "I use ChatGPT, daily."
    )
  }

  func testContentRangeParserCrossesRustBridge() {
    let range = parseContentRange(value: " BYTES 65-99/100 ")

    XCTAssertEqual(range?.start, 65)
    XCTAssertEqual(range?.end, 99)
    XCTAssertEqual(range?.total, 100)
    XCTAssertNil(parseContentRange(value: "bytes 0-3/3"))
    XCTAssertTrue(
      validatePartialContentRange(
        value: "bytes 65-99/100",
        expectedOffset: 65,
        expectedSize: 100
      )
    )
    XCTAssertFalse(
      validatePartialContentRange(
        value: "bytes 65-98/100",
        expectedOffset: 65,
        expectedSize: 100
      )
    )
  }

  func testSharedHistoryRecordAndTextSelectionCrossRustBridge() {
    let entry = HistoryEntry(
      id: 17,
      fileName: "capture.wav",
      timestamp: 1_798_326_400,
      saved: false,
      title: "Recording",
      transcriptionText: "raw",
      postProcessedText: "polished",
      postProcessPrompt: nil,
      postProcessRequested: true,
      postProcessSkipReason: nil,
      userCorrectedText: "  corrected\n "
    )

    XCTAssertEqual(
      selectHistoryText(entry: entry),
      "  corrected\n "
    )
    var uncorrectedEntry = entry
    uncorrectedEntry.userCorrectedText = nil
    XCTAssertEqual(
      selectHistoryText(entry: uncorrectedEntry),
      "polished"
    )
  }

  func testHistoryPaginationCrossesRustBridge() {
    let entry = HistoryEntry(
      id: 17,
      fileName: "capture.wav",
      timestamp: 1_798_326_400,
      saved: false,
      title: "Recording",
      transcriptionText: "recognized",
      postProcessedText: nil,
      postProcessPrompt: nil,
      postProcessRequested: false,
      postProcessSkipReason: nil,
      userCorrectedText: nil
    )

    let page = paginateHistoryEntries(entries: [entry, entry, entry], limit: 2)

    XCTAssertEqual(page.entries, [entry, entry])
    XCTAssertTrue(page.hasMore)

    let unboundedPage = paginateHistoryEntries(entries: [entry], limit: nil)
    XCTAssertEqual(unboundedPage.entries, [entry])
    XCTAssertFalse(unboundedPage.hasMore)
  }

  func testMixedErrorRateCountsHanCharactersAndEnglishWords() {
    let result = MixedLanguageErrorRate.measure(
      reference: "你好, app!",
      hypothesis: "你啊 application"
    )

    XCTAssertEqual(result?.editCount, 2)
    XCTAssertEqual(result?.referenceTokenCount, 3)
    XCTAssertEqual(result?.rate ?? -1, 2.0 / 3.0, accuracy: 0.000_001)
  }

  func testMixedErrorRateIgnoresPunctuationWhitespaceAndCase() {
    let result = MixedLanguageErrorRate.measure(
      reference: "你好, Don't use AI!",
      hypothesis: "你好 don't\nuse ai"
    )

    XCTAssertEqual(result?.editCount, 0)
    XCTAssertEqual(result?.referenceTokenCount, 5)
  }

  func testMixedErrorRateIsUnavailableForAnEmptyReference() {
    XCTAssertNil(MixedLanguageErrorRate.measure(reference: " \n", hypothesis: "text"))
  }

  func testASCENDManifestDecodesSnakeCaseModelName() throws {
    let manifestData = Data(
      #"""
      {"dataset":"CAiRE/ASCEND","revision":"revision","split":"test","selection":"mixed","license":"CC-BY-SA-4.0","model_name":"Qwen Q4","samples":[]}
      """#.utf8
    )

    let manifest = try JSONDecoder().decode(
      ASRCorpusEvaluationManifest.self,
      from: manifestData
    )

    XCTAssertEqual(manifest.modelName, "Qwen Q4")
  }

  func testASCENDEvaluationAcceptsOnlyPinnedHeldOutSplitSizes() {
    XCTAssertEqual(ASRCorpusEvaluationReport.expectedSampleCount(for: "test"), 358)
    XCTAssertEqual(ASRCorpusEvaluationReport.expectedSampleCount(for: "validation"), 191)
    XCTAssertNil(ASRCorpusEvaluationReport.expectedSampleCount(for: "train"))
  }

  func testASCENDSpeakerCountsCanBeSerializedAsJSON() throws {
    let samples = [
      ASRCorpusEvaluationSample(
        id: "00001",
        filename: "test-mixed-00001.wav",
        reference: "你好",
        durationSeconds: 1,
        sha256: "hash-1",
        speakerID: 17,
        topic: "education"
      ),
      ASRCorpusEvaluationSample(
        id: "00002",
        filename: "test-mixed-00002.wav",
        reference: "hello 你好",
        durationSeconds: 1,
        sha256: "hash-2",
        speakerID: 17,
        topic: "persona"
      ),
    ]

    let speakerCounts = ASRCorpusEvaluationReport.speakerCounts(for: samples)

    XCTAssertEqual(speakerCounts, ["17": 2])
    XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["speakerCounts": speakerCounts]))
  }

  func testMachineIdentifierUsesTheSimulatorModelIdentifier() {
    #if targetEnvironment(simulator)
      let expectedIdentifier =
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "arm64"
      XCTAssertEqual(machineIdentifier(), expectedIdentifier)
    #endif
  }

  func testModelLanguagePolicyCrossesRustBridge() {
    XCTAssertEqual(
      canonicalizeSupportedLanguages(languages: ["en", "zh-Hans", "zh-Hant"]),
      ["en", "zh"]
    )
    XCTAssertEqual(
      resolveEffectiveLanguage(
        intent: "en",
        supportedLanguages: ["en-US", "zh-CN"],
        supportsLanguageDetection: false
      ),
      "en-US"
    )
  }

  func testConfidenceGatedOutputLanguageDetectionCrossesRustBridge() {
    XCTAssertEqual(
      detectOutputLanguageForText(
        text: "eu vi um carro na rua ontem de manhã quando fui ao mercado",
        supportedLanguages: ["en", "pt", "es"]
      ),
      "pt"
    )
    XCTAssertNil(
      detectOutputLanguageForText(
        text: "um ok",
        supportedLanguages: ["en", "pt"]
      )
    )
  }

  func testRealModelTranscribesProvidedAudioThroughSimulatorBridge() throws {
    guard
      let documentsDirectory = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first
    else {
      throw XCTSkip("The simulator app documents directory is unavailable.")
    }
    let evaluationDirectory = documentsDirectory.appendingPathComponent(
      "yanyu-inference-smoke",
      isDirectory: true
    )
    let modelURL = evaluationDirectory.appendingPathComponent("model.gguf")
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw XCTSkip(
        "Place a local GGUF model and FLEURS WAV fixtures in Documents/yanyu-inference-smoke.")
    }

    let transcriber = try Transcriber.loadModel(modelPath: modelURL.path)
    for (filename, expectedLanguage) in [("fleurs-zh.wav", "zh"), ("fleurs-en.wav", "en")] {
      let audioPath = evaluationDirectory.appendingPathComponent(filename).path
      guard FileManager.default.fileExists(atPath: audioPath) else {
        throw XCTSkip("A FLEURS WAV fixture is missing from Documents/yanyu-inference-smoke.")
      }
      let result = try transcriber.transcribeFile(audioPath: audioPath, language: nil)

      XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertEqual(result.detectedLanguage, expectedLanguage, filename)
      XCTAssertGreaterThan(result.audioDurationMs, 0)
    }
  }

  @MainActor
  func testASCENDMixedTestSetWithLocalModel() async throws {
    guard
      let documentsDirectory = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
      ).first
    else {
      throw XCTSkip("The app documents directory is unavailable.")
    }

    let evaluationDirectory = documentsDirectory.appendingPathComponent(
      "ascend-evaluation",
      isDirectory: true
    )
    let manifestURL = evaluationDirectory.appendingPathComponent("evaluation-manifest.json")
    let modelURL = evaluationDirectory.appendingPathComponent("model.gguf")
    guard
      FileManager.default.fileExists(atPath: manifestURL.path),
      FileManager.default.fileExists(atPath: modelURL.path)
    else {
      throw XCTSkip(
        "Stage the Qwen GGUF and ASCEND evaluation manifest/audio in Documents/ascend-evaluation."
      )
    }

    let manifest = try JSONDecoder().decode(
      ASRCorpusEvaluationManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    guard
      manifest.dataset == "CAiRE/ASCEND",
      manifest.revision == "737e9800ae31be9932ba8464c80366559bd28424",
      manifest.license == "CC-BY-SA-4.0",
      ASRCorpusEvaluationReport.expectedSampleCount(for: manifest.split)
        == manifest.samples.count
    else {
      XCTFail("The staged ASCEND manifest does not match a pinned mixed held-out split.")
      return
    }

    for sample in manifest.samples {
      guard URL(fileURLWithPath: sample.filename).lastPathComponent == sample.filename else {
        XCTFail("Unsafe audio filename in the ASCEND manifest.")
        return
      }
      let audioURL = evaluationDirectory.appendingPathComponent(sample.filename)
      guard FileManager.default.fileExists(atPath: audioURL.path) else {
        XCTFail("The ASCEND fixture is missing: \(sample.filename)")
        return
      }
      guard let audioHash = await InferenceEvaluation.sha256(at: audioURL) else {
        XCTFail("Could not hash the ASCEND fixture: \(sample.filename)")
        return
      }
      guard audioHash == sample.sha256 else {
        XCTFail("ASCEND fixture hash mismatch: \(sample.filename)")
        return
      }
    }

    guard let modelHash = await InferenceEvaluation.sha256(at: modelURL) else {
      XCTFail("Could not hash the staged ASR model.")
      return
    }
    let modelSize =
      try FileManager.default.attributesOfItem(atPath: modelURL.path)[.size]
      as? NSNumber

    let resourceMonitor = DeviceResourceMonitor()
    resourceMonitor.start()
    let modelLoadStart = ProcessInfo.processInfo.systemUptime
    let transcriber = try await Task.detached(priority: .userInitiated) {
      try Transcriber.loadModel(modelPath: modelURL.path)
    }.value
    let modelLoadDurationMs = Int(
      (ProcessInfo.processInfo.systemUptime - modelLoadStart) * 1_000
    )

    var totalEditCount = 0
    var totalReferenceTokenCount = 0
    var totalAudioDurationMs: UInt64 = 0
    var totalProcessingDurationMs: UInt64 = 0
    var outputWithBothScripts = 0
    var detectedLanguages: [String: Int] = [:]
    var failedSampleIDs: [String] = []
    let progressURL = evaluationDirectory.appendingPathComponent("evaluation-progress.txt")
    let checkpointProgress: (Int) throws -> Void = { completedSampleCount in
      guard
        completedSampleCount.isMultiple(of: 16)
          || completedSampleCount == manifest.samples.count
      else {
        return
      }
      try "\(completedSampleCount)/\(manifest.samples.count)\n".write(
        to: progressURL,
        atomically: true,
        encoding: .utf8
      )
    }

    for (sampleIndex, sample) in manifest.samples.enumerated() {
      let audioURL = evaluationDirectory.appendingPathComponent(sample.filename)
      let result: TranscriptResult
      do {
        result = try await Task.detached(priority: .userInitiated) {
          try transcriber.transcribeFile(audioPath: audioURL.path, language: nil)
        }.value
      } catch {
        failedSampleIDs.append(sample.id)
        if let score = MixedLanguageErrorRate.measure(
          reference: sample.reference,
          hypothesis: ""
        ) {
          totalEditCount += score.editCount
          totalReferenceTokenCount += score.referenceTokenCount
        }
        totalAudioDurationMs += UInt64(sample.durationSeconds * 1_000)
        try checkpointProgress(sampleIndex + 1)
        continue
      }

      if let score = MixedLanguageErrorRate.measure(
        reference: sample.reference,
        hypothesis: result.text
      ) {
        totalEditCount += score.editCount
        totalReferenceTokenCount += score.referenceTokenCount
      }
      totalAudioDurationMs += result.audioDurationMs
      totalProcessingDurationMs += result.processingDurationMs
      detectedLanguages[result.detectedLanguage ?? "unknown", default: 0] += 1
      if MixedLanguageErrorRate.containsHan(result.text)
        && MixedLanguageErrorRate.containsLatinLetter(result.text)
      {
        outputWithBothScripts += 1
      }
      try checkpointProgress(sampleIndex + 1)
    }

    try "loop-complete: \(manifest.samples.count)/\(manifest.samples.count)\n".write(
      to: progressURL,
      atomically: true,
      encoding: .utf8
    )
    let batchDurationMs = Int(
      (ProcessInfo.processInfo.systemUptime - modelLoadStart) * 1_000
    )
    let resourceMeasurement = resourceMonitor.stop()
    try "resource-monitor-stopped\n".write(
      to: progressURL,
      atomically: true,
      encoding: .utf8
    )
    let mixedErrorRate =
      totalReferenceTokenCount > 0
      ? Double(totalEditCount) / Double(totalReferenceTokenCount)
      : nil
    let summary: [String: Any] = [
      "dataset": manifest.dataset,
      "revision": manifest.revision,
      "split": manifest.split,
      "selection": manifest.selection,
      "license": manifest.license,
      "samples": manifest.samples.count,
      "speakerCounts": ASRCorpusEvaluationReport.speakerCounts(for: manifest.samples),
      "topicCounts": Dictionary(grouping: manifest.samples, by: \.topic).mapValues(\.count),
      "model": manifest.modelName ?? modelURL.lastPathComponent,
      "modelSizeBytes": modelSize ?? NSNull(),
      "modelSHA256": modelHash,
      "device": machineIdentifier(),
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "modelLoadDurationMs": modelLoadDurationMs,
      "batchDurationMs": batchDurationMs,
      "audioDurationMs": totalAudioDurationMs,
      "coreProcessingDurationMs": totalProcessingDurationMs,
      "realTimeFactor": totalAudioDurationMs > 0
        ? Double(totalProcessingDurationMs) / Double(totalAudioDurationMs)
        : NSNull(),
      "metricDefinition":
        "NFKC-normalized, case-folded Han characters and non-Han words; punctuation and whitespace ignored",
      "mixedErrorRate": mixedErrorRate ?? NSNull(),
      "mixedErrorEdits": totalEditCount,
      "referenceTokens": totalReferenceTokenCount,
      "outputsWithBothScripts": outputWithBothScripts,
      "detectedLanguages": detectedLanguages,
      "failedSampleIDs": failedSampleIDs,
      "peakSampledPhysicalMemoryFootprintBytes": resourceMeasurement
        .peakSampledMemoryFootprintBytes ?? NSNull(),
      "thermalStates": resourceMeasurement.thermalStates,
      "memorySampleIntervalMs": resourceMeasurement.sampleIntervalMs,
    ]
    let reportData = try JSONSerialization.data(
      withJSONObject: summary,
      options: [.prettyPrinted, .sortedKeys]
    )
    try "report-serialized\n".write(
      to: progressURL,
      atomically: true,
      encoding: .utf8
    )
    let report = String(decoding: reportData, as: UTF8.self)
    try reportData.write(
      to: evaluationDirectory.appendingPathComponent("evaluation-report.json"),
      options: .atomic
    )
    try "report-written\n".write(
      to: progressURL,
      atomically: true,
      encoding: .utf8
    )
    print("YANYU_ASCEND_EVALUATION_BEGIN\n\(report)\nYANYU_ASCEND_EVALUATION_END")
  }

  func testFileHashFailureCrossesRustBridgeAsTypedError() {
    XCTAssertThrowsError(try computeFileSha256(path: "/tmp/yanyu-missing-hash-input")) { error in
      guard case CoreError.FileHash = error else {
        return XCTFail("Expected a typed Rust file-hash error, got \(error)")
      }
    }
  }

  private func machineIdentifier() -> String {
    #if targetEnvironment(simulator)
      if let simulatorModelIdentifier = ProcessInfo.processInfo.environment[
        "SIMULATOR_MODEL_IDENTIFIER"
      ] {
        return simulatorModelIdentifier
      }
    #endif

    var systemInfo = utsname()
    guard uname(&systemInfo) == 0 else {
      return "unknown"
    }
    return withUnsafeBytes(of: systemInfo.machine) { bytes in
      let identifier = bytes.bindMemory(to: CChar.self)
      return String(
        decoding: identifier.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    }
  }
}

private struct ASRCorpusEvaluationManifest: Decodable {
  let dataset: String
  let revision: String
  let split: String
  let selection: String
  let license: String
  let modelName: String?
  let samples: [ASRCorpusEvaluationSample]

  enum CodingKeys: String, CodingKey {
    case dataset
    case revision
    case split
    case selection
    case license
    case modelName = "model_name"
    case samples
  }
}

private struct ASRCorpusEvaluationSample: Decodable {
  let id: String
  let filename: String
  let reference: String
  let durationSeconds: Double
  let sha256: String
  let speakerID: Int
  let topic: String

  enum CodingKeys: String, CodingKey {
    case id
    case filename
    case reference
    case sha256
    case speakerID = "speaker_id"
    case durationSeconds = "duration_seconds"
    case topic
  }
}

private enum ASRCorpusEvaluationReport {
  static func expectedSampleCount(for split: String) -> Int? {
    switch split {
    case "test": 358
    case "validation": 191
    default: nil
    }
  }

  static func speakerCounts(for samples: [ASRCorpusEvaluationSample]) -> [String: Int] {
    Dictionary(grouping: samples, by: { String($0.speakerID) }).mapValues(\.count)
  }
}

private enum MixedLanguageErrorRate {
  struct Result: Equatable {
    let editCount: Int
    let referenceTokenCount: Int

    var rate: Double {
      Double(editCount) / Double(referenceTokenCount)
    }
  }

  static func measure(reference: String, hypothesis: String) -> Result? {
    let referenceTokens = tokenize(reference)
    guard !referenceTokens.isEmpty else {
      return nil
    }
    let hypothesisTokens = tokenize(hypothesis)
    return Result(
      editCount: editDistance(referenceTokens, hypothesisTokens),
      referenceTokenCount: referenceTokens.count
    )
  }

  static func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isHan)
  }

  static func containsLatinLetter(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      scalar.isASCII && CharacterSet.letters.contains(scalar)
    }
  }

  private static func tokenize(_ text: String) -> [String] {
    let scalars = Array(text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars)
    var tokens: [String] = []
    var word = String.UnicodeScalarView()

    func flushWord() {
      guard !word.isEmpty else {
        return
      }
      tokens.append(String(word).trimmingCharacters(in: CharacterSet(charactersIn: "'")))
      word.removeAll(keepingCapacity: true)
    }

    for (index, scalar) in scalars.enumerated() {
      if isHan(scalar) {
        flushWord()
        tokens.append(String(scalar))
      } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
      {
        word.append(scalar)
      } else if isApostrophe(scalar), !word.isEmpty,
        scalars.indices.contains(index + 1),
        !isHan(scalars[index + 1]),
        CharacterSet.alphanumerics.contains(scalars[index + 1])
      {
        word.append("'")
      } else {
        flushWord()
      }
    }
    flushWord()
    return tokens.filter { !$0.isEmpty }
  }

  private static func editDistance(_ left: [String], _ right: [String]) -> Int {
    var previous = Array(0...right.count)
    for (leftIndex, leftToken) in left.enumerated() {
      var current = [leftIndex + 1]
      current.reserveCapacity(right.count + 1)
      for (rightIndex, rightToken) in right.enumerated() {
        current.append(
          min(
            current[rightIndex] + 1,
            previous[rightIndex + 1] + 1,
            previous[rightIndex] + (leftToken == rightToken ? 0 : 1)
          )
        )
      }
      previous = current
    }
    return previous[right.count]
  }

  private static func isApostrophe(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value == 0x27 || scalar.value == 0x2019
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF,
      0x4E00...0x9FFF,
      0xF900...0xFAFF,
      0x20000...0x2FA1F,
      0x30000...0x323AF:
      true
    default:
      false
    }
  }
}

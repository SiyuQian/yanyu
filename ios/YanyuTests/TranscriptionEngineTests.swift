import SwiftData
import XCTest

@testable import Yanyu

final class TranscriptionEngineTests: XCTestCase {
  @MainActor
  func testLocalTranscriptionPreferencesPersistAndDefaultToFillerRemoval() throws {
    let suiteName = "YanyuTranscriptionPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstViewModel = DictationViewModel(
      transcriptionEngine: FakeTranscriptionEngine(),
      userDefaults: defaults
    )
    XCTAssertTrue(firstViewModel.fillerWordRemovalEnabled)

    try firstViewModel.addCustomWord("  ChatGPT  ")
    firstViewModel.setFillerWordRemovalEnabled(false)

    let relaunchedViewModel = DictationViewModel(
      transcriptionEngine: FakeTranscriptionEngine(),
      userDefaults: defaults
    )
    XCTAssertEqual(relaunchedViewModel.customWords, ["ChatGPT"])
    XCTAssertFalse(relaunchedViewModel.fillerWordRemovalEnabled)
  }

  @MainActor
  func testCustomWordsRejectSanitizedEmptyLongAndDuplicateEntries() throws {
    let suiteName = "YanyuTranscriptionPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let viewModel = DictationViewModel(
      transcriptionEngine: FakeTranscriptionEngine(),
      userDefaults: defaults
    )
    try viewModel.addCustomWord("ChatGPT")

    XCTAssertThrowsError(try viewModel.addCustomWord("chatgpt")) { error in
      XCTAssertEqual(error as? CustomWordPreferenceError, .duplicate(word: "chatgpt"))
    }
    XCTAssertThrowsError(try viewModel.addCustomWord("<>\"'")) { error in
      XCTAssertEqual(error as? CustomWordPreferenceError, .invalid)
    }
    XCTAssertThrowsError(try viewModel.addCustomWord(String(repeating: "x", count: 51))) { error in
      XCTAssertEqual(error as? CustomWordPreferenceError, .tooLong)
    }
    XCTAssertEqual(viewModel.customWords, ["ChatGPT"])
  }

  @MainActor
  func testSuccessfulTranscriptionAppliesCustomWordsAndLanguageGatedFillers() async throws {
    let suiteName = "YanyuTranscriptionPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let engine = FakeTranscriptionEngine()
    engine.transcriptionText = "um I use chat g p, uh"
    engine.detectedLanguage = "en"
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: engine,
      userDefaults: defaults
    )
    try viewModel.addCustomWord("ChatGPT")
    viewModel.handleIncompleteTranscription(kind: .repetition, partialText: nil)

    viewModel.retryTranscription(using: ModelContext(container))
    for _ in 0..<20 where viewModel.state == .transcribing {
      await Task.yield()
    }

    XCTAssertEqual(viewModel.transcript, "I use ChatGPT,")
    XCTAssertEqual(
      try container.mainContext.fetch(FetchDescriptor<TranscriptRecord>()).first?.text,
      "I use ChatGPT,")
  }

  @MainActor
  func testDisablingFillerRemovalPreservesLanguageSpecificWords() async throws {
    let suiteName = "YanyuTranscriptionPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let engine = FakeTranscriptionEngine()
    engine.transcriptionText = "um I think"
    engine.detectedLanguage = "en"
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: engine,
      userDefaults: defaults
    )
    viewModel.setFillerWordRemovalEnabled(false)
    viewModel.handleIncompleteTranscription(kind: .repetition, partialText: nil)

    viewModel.retryTranscription(using: ModelContext(container))
    for _ in 0..<20 where viewModel.state == .transcribing {
      await Task.yield()
    }

    XCTAssertEqual(viewModel.transcript, "um I think")
  }

  @MainActor
  func testPermissionDenialOffersSystemSettingsRecovery() {
    let viewModel = DictationViewModel(transcriptionEngine: FakeTranscriptionEngine())

    viewModel.errorKey = "iosApp.permissionDenied"
    XCTAssertTrue(viewModel.shouldOfferSystemSettingsRecovery)

    viewModel.errorKey = "iosApp.genericError"
    XCTAssertFalse(viewModel.shouldOfferSystemSettingsRecovery)
  }

  @MainActor
  func testViewModelForwardsCancellationToInjectedEngine() {
    let engine = FakeTranscriptionEngine()
    let viewModel = DictationViewModel(transcriptionEngine: engine)

    viewModel.cancelTranscription()

    XCTAssertEqual(engine.cancelCount, 1)
  }

  @MainActor
  func testTranscriptionPhaseProgressIsVisibleUntilTheEngineFinishes() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let engine = FakeTranscriptionEngine()
    engine.holdsTranscription = true
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: engine
    )
    viewModel.handleIncompleteTranscription(kind: .truncated, partialText: nil)

    viewModel.retryTranscription(using: ModelContext(container))
    await engine.waitUntilTranscriptionStarts()
    XCTAssertEqual(viewModel.transcriptionProgress, .preparingAudio)

    engine.reportProgress(.recognizing)
    XCTAssertEqual(viewModel.transcriptionProgress, .recognizing)

    engine.finishTranscription()
    for _ in 0..<20 where viewModel.state == .transcribing {
      await Task.yield()
    }
    XCTAssertNil(viewModel.transcriptionProgress)
    XCTAssertEqual(viewModel.transcript, "Recognized result")
  }

  @MainActor
  func testIncompleteTranscriptionKeepsAudioAndAllowsSavingReviewedPartialText() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: FakeTranscriptionEngine()
    )

    viewModel.handleIncompleteTranscription(kind: .truncated, partialText: "Part of the result")

    XCTAssertEqual(viewModel.transcript, "Part of the result")
    XCTAssertEqual(viewModel.errorKey, "iosApp.transcriptionTruncated")
    XCTAssertTrue(viewModel.hasPendingAudioRecovery)
    XCTAssertTrue(viewModel.hasPartialTranscriptToSave)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingAudio.url.path))

    viewModel.updateTranscript("Reviewed result", using: context)
    viewModel.savePartialTranscript(using: context)

    XCTAssertEqual(
      try context.fetch(FetchDescriptor<TranscriptRecord>()).first?.text, "Reviewed result")
    XCTAssertFalse(viewModel.hasPartialTranscriptToSave)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingAudio.url.path))
  }

  @MainActor
  func testIncompleteTranscriptionWithoutPartialTextStillAllowsRetryAndDelete() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: FakeTranscriptionEngine()
    )

    viewModel.handleIncompleteTranscription(kind: .repetition, partialText: nil)

    XCTAssertEqual(viewModel.errorKey, "iosApp.transcriptionRepeated")
    XCTAssertFalse(viewModel.hasTranscriptForDisplay)
    XCTAssertTrue(viewModel.hasPendingAudioRecovery)
    XCTAssertTrue(viewModel.hasDiscardablePendingAudio)
    XCTAssertFalse(viewModel.hasPartialTranscriptToSave)
  }

  @MainActor
  func testEmptyTranscriptionRetainsAudioAndOffersRecovery() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let engine = FakeTranscriptionEngine()
    engine.transcriptionText = " \n  "
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: engine
    )
    viewModel.handleIncompleteTranscription(kind: .repetition, partialText: nil)

    viewModel.retryTranscription(using: context)
    for _ in 0..<20 where viewModel.state == .transcribing {
      await Task.yield()
    }

    XCTAssertEqual(viewModel.errorKey, "iosApp.emptyTranscription")
    XCTAssertTrue(viewModel.hasPendingAudioRecovery)
    XCTAssertTrue(viewModel.hasDiscardablePendingAudio)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingAudio.url.path))
    XCTAssertTrue(try context.fetch(FetchDescriptor<TranscriptRecord>()).isEmpty)
  }

  @MainActor
  func testPartialTextCanBeSavedAfterTheUserDeletesRetainedAudio() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: FakeTranscriptionEngine()
    )
    viewModel.handleIncompleteTranscription(kind: .truncated, partialText: "Partial result")

    viewModel.discardPendingAudio()

    XCTAssertFalse(viewModel.hasPendingAudioRecovery)
    XCTAssertTrue(viewModel.hasPartialTranscriptToSave)
    viewModel.savePartialTranscript(using: context)
    XCTAssertEqual(
      try context.fetch(FetchDescriptor<TranscriptRecord>()).first?.text, "Partial result")
  }

  @MainActor
  func testOverlongAudioOffersDeleteWithoutRetryingTheSameRecording() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let defaults = UserDefaults.standard
    let failureKey = "yanyu.ios.pending-audio-failure"
    defaults.removeObject(forKey: failureKey)
    defer { defaults.removeObject(forKey: failureKey) }
    let viewModel = DictationViewModel(
      pendingAudioFile: pendingAudio,
      transcriptionEngine: FakeTranscriptionEngine()
    )

    viewModel.handleInputTooLong()

    XCTAssertEqual(viewModel.errorKey, "iosApp.audioTooLong")
    XCTAssertFalse(viewModel.hasPendingAudioRecovery)
    XCTAssertTrue(viewModel.hasDiscardablePendingAudio)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingAudio.url.path))

    viewModel.discardPendingAudio()

    XCTAssertNil(defaults.string(forKey: failureKey))
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingAudio.url.path))
  }

  @MainActor
  func testOverlongAudioRecoveryRemainsDeleteOnlyAfterRelaunch() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let defaults = UserDefaults.standard
    let recoveryKeys = [
      "yanyu.ios.pending-audio-saved",
      "yanyu.ios.pending-audio-failure",
      "yanyu.ios.debug-model-path",
      "yanyu.ios.debug-model-name",
      "yanyu.ios.debug-model-package-id",
      "yanyu.ios.debug-model-package-version",
    ]
    recoveryKeys.forEach(defaults.removeObject(forKey:))
    defer { recoveryKeys.forEach(defaults.removeObject(forKey:)) }

    let firstSession = DictationViewModel(pendingAudioFile: pendingAudio)
    firstSession.handleInputTooLong()

    let relaunchedSession = DictationViewModel(
      transcriptionEngine: FakeTranscriptionEngine(),
      recoverPendingAudio: { pendingAudio }
    )
    await relaunchedSession.restoreLocalStateIfPresent()

    XCTAssertEqual(relaunchedSession.errorKey, "iosApp.audioTooLong")
    XCTAssertFalse(relaunchedSession.hasPendingAudioRecovery)
    XCTAssertTrue(relaunchedSession.hasDiscardablePendingAudio)
  }

  @MainActor
  func testRestoringModelKeepsTheOverlongAudioRecoveryMessage() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)
    let sourceURL = directory.appendingPathComponent("source.gguf")
    try minimalGGUF(architecture: "whisper").write(to: sourceURL)
    let defaults = UserDefaults.standard
    let recoveryKeys = [
      "yanyu.ios.pending-audio-saved",
      "yanyu.ios.pending-audio-failure",
      "yanyu.ios.debug-model-path",
      "yanyu.ios.debug-model-name",
      "yanyu.ios.debug-model-package-id",
      "yanyu.ios.debug-model-package-version",
    ]
    recoveryKeys.forEach(defaults.removeObject(forKey:))
    defer { recoveryKeys.forEach(defaults.removeObject(forKey:)) }
    let store = ModelPackageStore(
      modelsDirectory: directory.appendingPathComponent("installed")
    )
    await DictationViewModel(
      transcriptionEngine: FakeTranscriptionEngine(),
      modelPackageStore: store
    ).importLocalModel(from: sourceURL)
    DictationViewModel(pendingAudioFile: pendingAudio).handleInputTooLong()
    let restoredEngine = FakeTranscriptionEngine()
    let relaunchedSession = DictationViewModel(
      transcriptionEngine: restoredEngine,
      modelPackageStore: store,
      recoverPendingAudio: { pendingAudio }
    )

    await relaunchedSession.restoreLocalStateIfPresent()

    XCTAssertTrue(relaunchedSession.isModelLoaded)
    XCTAssertEqual(relaunchedSession.errorKey, "iosApp.audioTooLong")
    XCTAssertFalse(relaunchedSession.hasPendingAudioRecovery)
    XCTAssertTrue(relaunchedSession.hasDiscardablePendingAudio)
  }

  @MainActor
  func testImportsAndRestoresVerifiedInstalledPackage() async throws {
    let modelsDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory) }
    let sourceURL = modelsDirectory.appendingPathComponent("source.gguf")
    let sourceData = minimalGGUF(architecture: "whisper")
    try sourceData.write(to: sourceURL)
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "yanyu.ios.debug-model-path")
    defaults.removeObject(forKey: "yanyu.ios.debug-model-name")
    defaults.removeObject(forKey: "yanyu.ios.debug-model-package-id")
    defaults.removeObject(forKey: "yanyu.ios.debug-model-package-version")
    defer {
      defaults.removeObject(forKey: "yanyu.ios.debug-model-path")
      defaults.removeObject(forKey: "yanyu.ios.debug-model-name")
      defaults.removeObject(forKey: "yanyu.ios.debug-model-package-id")
      defaults.removeObject(forKey: "yanyu.ios.debug-model-package-version")
    }

    let engine = FakeTranscriptionEngine()
    let store = ModelPackageStore(
      modelsDirectory: modelsDirectory.appendingPathComponent("installed"))
    let viewModel = DictationViewModel(transcriptionEngine: engine, modelPackageStore: store)
    await viewModel.importLocalModel(from: sourceURL)

    let loadedURL = try XCTUnwrap(engine.loadedModelURL)
    XCTAssertTrue(loadedURL.path.contains("/Packages/"))
    XCTAssertEqual(try Data(contentsOf: loadedURL), sourceData)
    XCTAssertEqual(defaults.string(forKey: "yanyu.ios.debug-model-path"), loadedURL.path)
    XCTAssertNotNil(defaults.string(forKey: "yanyu.ios.debug-model-package-id"))
    XCTAssertEqual(defaults.string(forKey: "yanyu.ios.debug-model-package-version"), "1")
    XCTAssertTrue(viewModel.isModelLoaded)

    let restoreEngine = FakeTranscriptionEngine()
    let restoredViewModel = DictationViewModel(
      transcriptionEngine: restoreEngine,
      modelPackageStore: store
    )
    await restoredViewModel.restoreLocalStateIfPresent()

    XCTAssertEqual(restoreEngine.loadedModelURL, loadedURL)
    XCTAssertTrue(restoredViewModel.isModelLoaded)
    XCTAssertNil(restoredViewModel.errorKey)
  }

  @MainActor
  func testRejectedLocalModelDoesNotRemainInPackageStore() async throws {
    let modelsDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory) }
    let sourceURL = modelsDirectory.appendingPathComponent("invalid.gguf")
    try Data("not a GGUF model".utf8).write(to: sourceURL)
    let storeDirectory = modelsDirectory.appendingPathComponent("installed")
    let engine = FakeTranscriptionEngine()
    let store = ModelPackageStore(modelsDirectory: storeDirectory)
    let viewModel = DictationViewModel(transcriptionEngine: engine, modelPackageStore: store)

    await viewModel.importLocalModel(from: sourceURL)

    XCTAssertEqual(viewModel.errorKey, "iosApp.invalidModel")
    XCTAssertNil(engine.loadedModelURL)
    let installedFiles = try FileManager.default.subpathsOfDirectory(atPath: storeDirectory.path)
    XCTAssertFalse(installedFiles.contains("model.gguf"))
  }

  @MainActor
  func testRestoreRejectsInstalledPackageWithChangedAssetSize() async throws {
    let modelsDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: modelsDirectory) }
    let sourceURL = modelsDirectory.appendingPathComponent("source.gguf")
    try minimalGGUF(architecture: "whisper").write(to: sourceURL)
    let defaults = UserDefaults.standard
    for key in modelPreferenceKeys {
      defaults.removeObject(forKey: key)
    }
    defer {
      for key in modelPreferenceKeys {
        defaults.removeObject(forKey: key)
      }
    }

    let store = ModelPackageStore(
      modelsDirectory: modelsDirectory.appendingPathComponent("installed"))
    let importEngine = FakeTranscriptionEngine()
    await DictationViewModel(
      transcriptionEngine: importEngine,
      modelPackageStore: store
    ).importLocalModel(from: sourceURL)
    let installedURL = try XCTUnwrap(importEngine.loadedModelURL)
    try Data("tampered with a different size".utf8).write(to: installedURL)

    let restoreEngine = FakeTranscriptionEngine()
    let viewModel = DictationViewModel(
      transcriptionEngine: restoreEngine,
      modelPackageStore: store
    )
    await viewModel.restoreLocalStateIfPresent()

    XCTAssertNil(restoreEngine.loadedModelURL)
    XCTAssertEqual(viewModel.errorKey, "iosApp.modelPackageDamaged")
    XCTAssertNil(defaults.string(forKey: "yanyu.ios.debug-model-path"))
  }

  private var modelPreferenceKeys: [String] {
    [
      "yanyu.ios.debug-model-path",
      "yanyu.ios.debug-model-name",
      "yanyu.ios.debug-model-package-id",
      "yanyu.ios.debug-model-package-version",
    ]
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func minimalGGUF(architecture: String) -> Data {
    var data = Data("GGUF".utf8)
    data.appendLittleEndian(UInt32(3))
    data.appendLittleEndian(UInt64(0))
    data.appendLittleEndian(UInt64(1))
    data.appendGGUFString("general.architecture")
    data.appendLittleEndian(UInt32(8))
    data.appendGGUFString(architecture)
    return data
  }
}

@MainActor
private final class FakeTranscriptionEngine: TranscriptionEngine {
  private(set) var cancelCount = 0
  private(set) var loadedModelURL: URL?
  var transcriptionText = ""
  var detectedLanguage: String?
  var holdsTranscription = false
  private var transcriptionStarted = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var resultWaiter: CheckedContinuation<TranscriptionOutcome, Never>?
  private var progressHandler: (@MainActor (TranscriptionProgress) -> Void)?

  func loadModel(at modelURL: URL) async throws {
    loadedModelURL = modelURL
  }

  func transcribe(
    fileAt audioURL: URL,
    language: String?,
    progress: @escaping @MainActor (TranscriptionProgress) -> Void
  ) async throws -> TranscriptionOutcome {
    progress(.preparingAudio)
    progressHandler = progress
    if holdsTranscription {
      return await withCheckedContinuation { continuation in
        resultWaiter = continuation
        transcriptionStarted = true
        startWaiter?.resume()
        startWaiter = nil
      }
    }
    return TranscriptionOutcome(
      text: transcriptionText,
      detectedLanguage: detectedLanguage,
      audioDurationMs: 0,
      processingDurationMs: 0
    )
  }

  func waitUntilTranscriptionStarts() async {
    guard !transcriptionStarted else {
      return
    }
    await withCheckedContinuation { continuation in
      startWaiter = continuation
    }
  }

  func reportProgress(_ progress: TranscriptionProgress) {
    progressHandler?(progress)
  }

  func finishTranscription() {
    resultWaiter?.resume(
      returning: TranscriptionOutcome(
        text: "Recognized result",
        detectedLanguage: nil,
        audioDurationMs: 0,
        processingDurationMs: 0
      )
    )
    resultWaiter = nil
  }

  func cancel() {
    cancelCount += 1
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
  }

  fileprivate mutating func appendGGUFString(_ value: String) {
    let bytes = Data(value.utf8)
    appendLittleEndian(UInt64(bytes.count))
    append(bytes)
  }
}

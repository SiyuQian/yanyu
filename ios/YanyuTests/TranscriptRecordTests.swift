import SwiftData
import XCTest

@testable import Yanyu

final class TranscriptRecordTests: XCTestCase {
  @MainActor
  func testTranscriptStoreIsExcludedFromDeviceBackups() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try TranscriptStore.makeContainer(applicationSupportDirectory: directory)
    let historyDirectory = directory.appendingPathComponent(
      "com.siyuqian.yanyu.ios",
      isDirectory: true
    )
    let values = try historyDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])

    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  @MainActor
  func testTranscriptCanBeSavedAndEditedInLocalHistory() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: configuration
    )
    let context = ModelContext(container)
    let record = TranscriptRecord(text: "First draft")
    context.insert(record)
    try context.save()

    record.text = "Edited transcript"
    try context.save()

    let savedRecords = try context.fetch(FetchDescriptor<TranscriptRecord>())
    XCTAssertEqual(savedRecords.count, 1)
    XCTAssertEqual(savedRecords.first?.text, "Edited transcript")
  }

  @MainActor
  func testEditedTranscriptSurvivesReloadingHistoryStore() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let schema = Schema([TranscriptRecord.self])
    let storeURL = directory.appendingPathComponent("history.store")
    let configuration = ModelConfiguration(
      "TestHistory",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )

    do {
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      let record = TranscriptRecord(text: "Original transcript")
      context.insert(record)
      try context.save()

      record.text = "Edited transcript"
      try context.save()
    }

    let reloadedContainer = try ModelContainer(for: schema, configurations: [configuration])
    let reloadedContext = ModelContext(reloadedContainer)
    let savedRecords = try reloadedContext.fetch(FetchDescriptor<TranscriptRecord>())

    XCTAssertEqual(savedRecords.map(\.text), ["Edited transcript"])
  }

  @MainActor
  func testDeleteAllHistoryRemovesEverySavedTranscript() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: configuration
    )
    let context = ModelContext(container)
    context.insert(TranscriptRecord(text: "First transcript"))
    context.insert(TranscriptRecord(text: "Second transcript"))
    try context.save()

    try TranscriptStore.deleteAllHistory(using: context)

    XCTAssertTrue(try context.fetch(FetchDescriptor<TranscriptRecord>()).isEmpty)
  }

  @MainActor
  func testClearingHistoryResetsSelectedTranscriptInMemory() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: configuration
    )
    let context = ModelContext(container)
    let record = TranscriptRecord(text: "Saved transcript")
    context.insert(record)
    try context.save()

    let viewModel = DictationViewModel()
    viewModel.select(record)
    try TranscriptStore.deleteAllHistory(using: context)
    viewModel.clearTranscriptAfterHistoryDeletion()

    XCTAssertFalse(viewModel.hasTranscriptForDisplay)
    XCTAssertEqual(viewModel.state, .ready)
  }

  @MainActor
  func testEditingExistingTranscriptExposesSaveRetryAndPersists() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: configuration
    )
    let context = ModelContext(container)
    let record = TranscriptRecord(text: "Original")
    context.insert(record)
    try context.save()

    let viewModel = DictationViewModel()
    viewModel.select(record)
    viewModel.updateTranscript("Edited", using: context)

    XCTAssertTrue(viewModel.hasPendingTranscriptSave)
    viewModel.savePendingTranscript(using: context)

    XCTAssertFalse(viewModel.hasPendingTranscriptSave)
    XCTAssertEqual(try context.fetch(FetchDescriptor<TranscriptRecord>()).first?.text, "Edited")
  }

  @MainActor
  func testSavingAnUnrelatedHistoryEditKeepsRecoveredAudio() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pendingAudio = try TemporaryAudioFile(in: directory)
    try Data([1, 2, 3]).write(to: pendingAudio.url)

    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: TranscriptRecord.self,
      configurations: configuration
    )
    let context = ModelContext(container)
    let record = TranscriptRecord(text: "Original")
    context.insert(record)
    try context.save()

    let viewModel = DictationViewModel(pendingAudioFile: pendingAudio)
    viewModel.select(record)
    viewModel.updateTranscript("Edited", using: context)
    viewModel.savePendingTranscript(using: context)

    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingAudio.url.path))
  }
}

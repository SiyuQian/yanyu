import Foundation
import SwiftData

@MainActor
enum TranscriptStore {
  static func deleteAllHistory(using context: ModelContext) throws {
    let records = try context.fetch(FetchDescriptor<TranscriptRecord>())
    guard !records.isEmpty else {
      return
    }

    for record in records {
      context.delete(record)
    }
    do {
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
  }

  static func makeContainer(applicationSupportDirectory: URL? = nil) throws -> ModelContainer {
    let supportDirectory: URL
    if let applicationSupportDirectory {
      supportDirectory = applicationSupportDirectory
    } else {
      supportDirectory = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    }

    let historyDirectory = supportDirectory.appendingPathComponent(
      "com.siyuqian.yanyu.ios",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: historyDirectory,
      withIntermediateDirectories: true
    )
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableHistoryDirectory = historyDirectory
    try mutableHistoryDirectory.setResourceValues(resourceValues)

    let schema = Schema([TranscriptRecord.self])
    let storeURL = historyDirectory.appendingPathComponent("transcripts.store")
    let configuration = ModelConfiguration(
      "YanyuHistory",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    return try ModelContainer(for: schema, configurations: [configuration])
  }
}

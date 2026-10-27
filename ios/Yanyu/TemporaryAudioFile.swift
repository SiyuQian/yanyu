import Foundation

enum TemporaryAudioFileError: Error, Equatable {
  case pendingRecordingExists
}

struct TemporaryAudioFile: Sendable {
  let url: URL

  init() throws {
    try self.init(recoveryIn: Self.recoveryDirectory())
  }

  init(in directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    url =
      directory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("wav")
  }

  init(recoveryIn directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Self.excludeFromBackup(directory)
    let pendingURL = directory.appendingPathComponent("pending-recording.wav")
    guard !FileManager.default.fileExists(atPath: pendingURL.path) else {
      throw TemporaryAudioFileError.pendingRecordingExists
    }
    url = pendingURL
  }

  static func recoverPending() throws -> TemporaryAudioFile? {
    try recoverPending(in: recoveryDirectory())
  }

  static func recoverPending(in directory: URL) throws -> TemporaryAudioFile? {
    let pendingURL = directory.appendingPathComponent("pending-recording.wav")
    guard FileManager.default.fileExists(atPath: pendingURL.path) else {
      return nil
    }
    return TemporaryAudioFile(url: pendingURL)
  }

  func remove() throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return
    }
    try FileManager.default.removeItem(at: url)
  }

  private init(url: URL) {
    self.url = url
  }

  private static func recoveryDirectory() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let applicationDirectory = applicationSupport.appendingPathComponent(
      "com.siyuqian.yanyu.ios",
      isDirectory: true
    )
    let directory = applicationDirectory.appendingPathComponent(
      "RecoveryAudio",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try excludeFromBackup(directory)
    return directory
  }

  private static func excludeFromBackup(_ directory: URL) throws {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableDirectory = directory
    try mutableDirectory.setResourceValues(resourceValues)
  }
}

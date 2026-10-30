import Foundation

/// The only data shared with the keyboard; ordinary dictation and history stay private to the app.
struct KeyboardSessionSnapshot: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable {
    case recording, transcribing, ready, failed
  }
  let id: UUID
  let phase: Phase
  let updatedAt: Date
  var text: String? = nil
}

struct KeyboardSessionStore {
  static let groupIdentifier = "group.com.siyuqian.yanyu"
  let directory: URL

  static func shared() -> Self? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupIdentifier
      )
    else { return nil }
    return Self(directory: container.appendingPathComponent("KeyboardDictation", isDirectory: true))
  }

  func write(_ snapshot: KeyboardSessionSnapshot) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var excludedDirectory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excludedDirectory.setResourceValues(values)
    try encode(snapshot, to: "session.json")
  }

  func read(now: Date = .now) throws -> KeyboardSessionSnapshot? {
    guard let snapshot = try decode(KeyboardSessionSnapshot.self, from: "session.json") else {
      return nil
    }
    let age = now.timeIntervalSince(snapshot.updatedAt)
    let lifetime: TimeInterval = snapshot.phase == .ready ? 300 : 5
    guard age >= -1, age <= lifetime,
      (snapshot.text?.utf8.count ?? 0) <= 100_000,
      snapshot.phase != .ready
        || !(snapshot.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return snapshot
  }

  func requestStop(for id: UUID, now: Date = .now) throws {
    guard let snapshot = try read(now: now), snapshot.id == id, snapshot.phase == .recording else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    // Separate files keep keyboard commands from overwriting the app's heartbeat or result.
    try encode(id, to: "stop.json")
  }

  func stopRequested(for id: UUID) throws -> Bool {
    try decode(UUID.self, from: "stop.json") == id
  }

  func clear() throws {
    for name in ["session.json", "stop.json"] {
      let url = directory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  private func encode(_ value: some Encodable, to name: String) throws {
    let data = try JSONEncoder().encode(value)
    #if os(iOS)
      try data.write(
        to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    #endif
  }

  private func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
    let url = directory.appendingPathComponent(name)
    do {
      let data = try Data(contentsOf: url)
      guard data.count <= 150_000 else { throw CocoaError(.fileReadCorruptFile) }
      return try JSONDecoder().decode(type, from: data)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }
}

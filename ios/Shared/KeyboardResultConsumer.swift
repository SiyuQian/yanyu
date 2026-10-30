import Foundation

struct KeyboardResultConsumer {
  let defaults: UserDefaults
  private let consumedIDKey = "yanyu.keyboard.consumed-result"

  func canInsert(_ snapshot: KeyboardSessionSnapshot, now: Date = .now) -> Bool {
    let age = now.timeIntervalSince(snapshot.updatedAt)
    return snapshot.phase == .ready && age >= -1 && age <= 300
      && !(snapshot.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (snapshot.text?.utf8.count ?? 0) <= 100_000
      && defaults.string(forKey: consumedIDKey) != snapshot.id.uuidString
  }

  func consume(_ snapshot: KeyboardSessionSnapshot, now: Date = .now) -> String? {
    guard canInsert(snapshot, now: now) else { return nil }
    // Persist before inserting so a recreated extension cannot insert the same result again.
    defaults.set(snapshot.id.uuidString, forKey: consumedIDKey)
    return snapshot.text
  }
}

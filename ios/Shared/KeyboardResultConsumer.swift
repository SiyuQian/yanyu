import Foundation

struct KeyboardTextContext: Equatable {
  let documentID: UUID
  let before: String?
  let after: String?
  let selected: String?
  let hasText: Bool

  fileprivate var readable: Self? {
    guard selected == nil, before != nil || after != nil || !hasText else { return nil }
    return Self(
      documentID: documentID, before: before ?? "", after: after ?? "", selected: nil,
      hasText: hasText)
  }
}

@MainActor
protocol KeyboardTextDocument: AnyObject {
  var context: KeyboardTextContext { get }
  func insertText(_ text: String)
  func deleteBackward()
}

@MainActor
final class KeyboardTextDelivery {
  private let consumer: KeyboardResultConsumer
  private var trackedContext: (id: UUID, text: KeyboardTextContext, confirmed: Bool)?
  private var insertion: (text: String, after: KeyboardTextContext)?

  init(defaults: UserDefaults) {
    consumer = KeyboardResultConsumer(defaults: defaults)
  }

  func prepareAutomaticInsertion(for sessionID: UUID, in context: KeyboardTextContext) {
    trackContext(for: sessionID, in: context)
    confirmAutomaticInsertion(for: sessionID)
  }

  func trackContext(for sessionID: UUID, in context: KeyboardTextContext) {
    invalidateContext()
    if let context = context.readable {
      trackedContext = (sessionID, context, false)
    }
  }

  func confirmAutomaticInsertion(for sessionID: UUID) {
    guard trackedContext?.id == sessionID else { return }
    trackedContext?.confirmed = true
  }

  func invalidateContext() {
    trackedContext = nil
    insertion = nil
  }

  func insert(
    _ result: KeyboardSessionSnapshot,
    into document: any KeyboardTextDocument,
    automatically: Bool = false
  ) -> Bool {
    if automatically, trackedContext?.confirmed != true || trackedContext?.id != result.id {
      return false
    }
    let before = document.context.readable
    if automatically, before != trackedContext?.text {
      invalidateContext()
      return false
    }
    guard let text = consumer.consume(result) else { return false }
    invalidateContext()
    document.insertText(text)

    // Offer undo only when the host exposes the complete insertion and its original boundary.
    if let before, let prefix = before.before, let suffix = before.after,
      hasInsertionBoundaries(prefix: prefix, text: text, suffix: suffix)
    {
      let after = KeyboardTextContext(
        documentID: before.documentID, before: prefix + text, after: suffix, selected: nil,
        hasText: true)
      if document.context.readable == after {
        insertion = (text, after)
      }
    }
    return true
  }

  func canUndo(in context: @autoclosure () -> KeyboardTextContext) -> Bool {
    guard let insertion else { return false }
    return context().readable == insertion.after
  }

  func undo(in document: any KeyboardTextDocument) -> Bool {
    guard canUndo(in: document.context), let insertion else {
      invalidateContext()
      return false
    }
    invalidateContext()
    for _ in insertion.text { document.deleteBackward() }
    return true
  }

  private func hasInsertionBoundaries(prefix: String, text: String, suffix: String) -> Bool {
    let start = prefix.utf16.count
    let end = start + text.utf16.count
    var offset = 0
    var foundStart = start == 0
    for character in prefix + text + suffix {
      offset += String(character).utf16.count
      if offset == start { foundStart = true }
      if offset == end { return foundStart }
      if offset > end { return false }
    }
    return false
  }
}

struct KeyboardResultConsumer {
  let defaults: UserDefaults
  private let consumedIDKey = "yanyu.keyboard.consumed-result"

  func hasConsumed(_ sessionID: UUID) -> Bool {
    defaults.string(forKey: consumedIDKey) == sessionID.uuidString
  }

  func canInsert(_ snapshot: KeyboardSessionSnapshot, now: Date = .now) -> Bool {
    let age = now.timeIntervalSince(snapshot.updatedAt)
    return snapshot.phase == .ready && age >= -1 && age <= 300
      && !(snapshot.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (snapshot.text?.utf8.count ?? 0) <= 100_000
      && !hasConsumed(snapshot.id)
  }

  func consume(_ snapshot: KeyboardSessionSnapshot, now: Date = .now) -> String? {
    guard canInsert(snapshot, now: now) else { return nil }
    // Persist before inserting so a recreated extension cannot insert the same result again.
    defaults.set(snapshot.id.uuidString, forKey: consumedIDKey)
    return snapshot.text
  }
}

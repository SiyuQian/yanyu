import Foundation
import Observation

/// Holds one short-lived user request until the app has restored its existing recording state.
@Observable
@MainActor
final class KeyboardDictationLaunchRequest {
  enum Outcome: Equatable {
    case start, onboardingRequired, modelRequired, busy, expired
  }

  static let shared = KeyboardDictationLaunchRequest()
  private(set) var requestedAt: Date?

  func request(now: Date = .now) {
    guard requestedAt == nil else { return }
    requestedAt = now
  }

  func consume(
    afterRestore: Bool,
    onboardingCompleted: Bool,
    modelLoaded: Bool,
    canStart: Bool,
    now: Date = .now
  ) -> Outcome? {
    guard let requestedAt else { return nil }
    let age = now.timeIntervalSince(requestedAt)
    guard age >= 0, age < 30 else {
      self.requestedAt = nil
      return .expired
    }
    guard afterRestore else { return nil }
    self.requestedAt = nil
    guard onboardingCompleted else { return .onboardingRequired }
    guard modelLoaded else { return .modelRequired }
    guard canStart else { return .busy }
    return .start
  }
}

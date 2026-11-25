import XCTest

@testable import Yanyu

final class KeyboardDictationLaunchRequestTests: XCTestCase {
  @MainActor
  func testRequestWaitsForRestoreThenStartsOnlyOnce() {
    let request = KeyboardDictationLaunchRequest()
    let now = Date(timeIntervalSince1970: 1_000)
    request.request(now: now)

    XCTAssertNil(
      request.consume(
        afterRestore: false, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now))
    XCTAssertEqual(
      request.consume(
        afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(2)), .start)
    XCTAssertNil(
      request.consume(
        afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(3)))
  }

  @MainActor
  func testDuplicateRequestDoesNotExtendConsentLifetime() {
    let request = KeyboardDictationLaunchRequest()
    let now = Date(timeIntervalSince1970: 1_000)
    request.request(now: now)
    request.request(now: now.addingTimeInterval(20))

    XCTAssertEqual(
      request.consume(
        afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(30)), .expired)
  }

  @MainActor
  func testUnavailablePrerequisiteConsumesRequestInsteadOfStartingAfterSetup() {
    let cases: [(Bool, Bool, Bool, KeyboardDictationLaunchRequest.Outcome)] = [
      (false, true, true, .onboardingRequired),
      (true, false, true, .modelRequired),
      (true, true, false, .busy),
    ]
    for (onboardingCompleted, modelLoaded, canStart, expected) in cases {
      let request = KeyboardDictationLaunchRequest()
      let now = Date(timeIntervalSince1970: 1_000)
      request.request(now: now)
      XCTAssertEqual(
        request.consume(
          afterRestore: true, onboardingCompleted: onboardingCompleted, modelLoaded: modelLoaded,
          canStart: canStart, now: now), expected)
      XCTAssertNil(
        request.consume(
          afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
          now: now.addingTimeInterval(1)))
    }
  }

  @MainActor
  func testExpiredRequestIsDiscardedEvenBeforeRestoreCompletes() {
    let request = KeyboardDictationLaunchRequest()
    let now = Date(timeIntervalSince1970: 1_000)
    request.request(now: now)

    XCTAssertEqual(
      request.consume(
        afterRestore: false, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(31)), .expired)
    XCTAssertNil(
      request.consume(
        afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(32)))
  }

  @MainActor
  func testClockMovingBackwardsDoesNotStartRecording() {
    let request = KeyboardDictationLaunchRequest()
    let now = Date(timeIntervalSince1970: 1_000)
    request.request(now: now)

    XCTAssertEqual(
      request.consume(
        afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(-1)), .expired)
  }

  @MainActor
  func testNewExplicitRequestCanStartAfterEarlierRequestExpired() {
    let request = KeyboardDictationLaunchRequest()
    let now = Date(timeIntervalSince1970: 1_000)
    request.request(now: now)
    _ = request.consume(
      afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
      now: now.addingTimeInterval(31))
    request.request(now: now.addingTimeInterval(40))

    XCTAssertEqual(
      request.consume(
        afterRestore: true, onboardingCompleted: true, modelLoaded: true, canStart: true,
        now: now.addingTimeInterval(41)), .start)
  }
}

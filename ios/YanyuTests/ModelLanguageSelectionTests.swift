import XCTest

@testable import Yanyu

final class ModelLanguageSelectionTests: XCTestCase {
  func testOffersOnlyLanguagesAndAutomaticModeSupportedByTheModel() {
    var selection = ModelLanguageSelection(intent: "auto")
    selection.updateCapabilities(
      capabilities(languages: ["en", "zh-Hans", "zh-Hant", "de"], detectsLanguage: true)
    )

    XCTAssertEqual(selection.options, ["auto", "en", "zh"])
    XCTAssertEqual(selection.pickerSelection, "auto")
    XCTAssertNil(selection.transcriptionLanguage)
  }

  func testNonDetectingModelShowsAndUsesItsEffectiveFallback() {
    var selection = ModelLanguageSelection(intent: "auto")
    selection.updateCapabilities(
      capabilities(languages: ["zh-Hant", "en-US"], detectsLanguage: false)
    )

    XCTAssertEqual(selection.options, ["zh", "en-US"])
    XCTAssertEqual(selection.intent, "auto")
    XCTAssertEqual(selection.pickerSelection, "en-US")
    XCTAssertEqual(selection.transcriptionLanguage, "en-US")
  }

  func testUnsupportedPersistedIntentFallsBackWithoutOverwritingTheIntent() {
    var selection = ModelLanguageSelection(intent: "fr")
    selection.updateCapabilities(
      capabilities(languages: ["zh-CN", "en-US"], detectsLanguage: true)
    )

    XCTAssertEqual(selection.intent, "fr")
    XCTAssertEqual(selection.pickerSelection, "auto")
    XCTAssertNil(selection.transcriptionLanguage)
  }

  private func capabilities(languages: [String], detectsLanguage: Bool) -> CapabilityProbe {
    CapabilityProbe(
      verdict: .compatible,
      displayName: nil,
      architecture: "whisper",
      variant: nil,
      languages: languages,
      supportsStreaming: nil,
      supportsTranslation: nil,
      supportsLanguageDetect: detectsLanguage
    )
  }
}

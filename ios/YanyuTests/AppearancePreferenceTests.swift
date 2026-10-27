import SwiftUI
import XCTest

@testable import Yanyu

final class AppearancePreferenceTests: XCTestCase {
  func testSystemAppearanceUsesDeviceSetting() {
    XCTAssertNil(AppearancePreference.system.preferredColorScheme)
  }

  func testLightAndDarkAppearanceMapToNativeColorSchemes() {
    XCTAssertEqual(AppearancePreference.light.preferredColorScheme, .light)
    XCTAssertEqual(AppearancePreference.dark.preferredColorScheme, .dark)
  }

  func testUnknownSavedAppearanceFallsBackToSystem() {
    XCTAssertEqual(AppearancePreference.resolve("unsupported"), .system)
  }
}

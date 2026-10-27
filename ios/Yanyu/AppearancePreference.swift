import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: Self { self }

  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system:
      nil
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  static func resolve(_ rawValue: String) -> Self {
    Self(rawValue: rawValue) ?? .system
  }
}

import Foundation

struct ModelLanguageSelection: Equatable {
  var intent: String
  private(set) var supportedLanguages: [String] = []
  private(set) var supportsLanguageDetection = false

  init(intent: String = "auto") {
    self.intent = intent
  }

  mutating func updateCapabilities(_ capabilities: CapabilityProbe) {
    let localCapabilities = deriveLocalModelCapabilities(probe: capabilities)
    supportedLanguages = localCapabilities.supportedLanguages
    supportsLanguageDetection = localCapabilities.supportsLanguageDetection
  }

  var options: [String] {
    let initialLanguages = supportedLanguages.filter { language in
      let base = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
      return base == "en" || base == "zh"
    }
    return (supportsLanguageDetection ? ["auto"] : []) + initialLanguages
  }

  var resolvedLanguage: String {
    resolveEffectiveLanguage(
      intent: intent,
      supportedLanguages: supportedLanguages,
      supportsLanguageDetection: supportsLanguageDetection
    )
  }

  var transcriptionLanguage: String? {
    resolvedLanguage == "auto" ? nil : resolvedLanguage
  }

  var pickerSelection: String? {
    options.contains(resolvedLanguage) ? resolvedLanguage : nil
  }
}

import Foundation
import SwiftData

@Model
final class TranscriptRecord {
  @Attribute(.unique) var id: UUID
  var text: String
  var createdAt: Date
  var detectedLanguage: String?
  var audioDurationMs: Int64
  var processingDurationMs: Int64

  init(
    text: String,
    createdAt: Date = .now,
    detectedLanguage: String? = nil,
    audioDurationMs: Int64 = 0,
    processingDurationMs: Int64 = 0
  ) {
    id = UUID()
    self.text = text
    self.createdAt = createdAt
    self.detectedLanguage = detectedLanguage
    self.audioDurationMs = audioDurationMs
    self.processingDurationMs = processingDurationMs
  }
}

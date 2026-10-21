// Nonpersonal synthetic audio only. No microphone or screen permission is requested.
import Foundation
import AVFoundation
@main struct MeetingCaptureHarness {
    static func main() async throws {
        guard #available(macOS 13, *) else { fatalError("macOS 13 required") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = try MeetingCapture(directory: directory.path, online: true)
        capture.establishOrigin()
        let buffer = AVAudioPCMBuffer(pcmFormat: capture.target, frameCapacity: 160)!
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = 0.25 }
        let origin = capture.origin
        capture.accept(buffer, at: origin, source: 0)
        capture.accept(buffer, at: origin + 0.02, source: 0)
        capture.accept(buffer, at: origin, source: 1)
        capture.writer.sync {}
        precondition(capture.frames == [480, 160], "gaps and per-source alignment")
        capture.accept(buffer, at: origin, source: 0)
        capture.writer.sync {}
        precondition(capture.frames[0] == 480, "late overlapping buffers must be trimmed")
        try capture.pause(true)
        capture.accept(buffer, at: origin + 0.1, source: 0)
        capture.writer.sync {}
        precondition(capture.frames[0] == 480, "paused callbacks must be discarded")
        try capture.pause(false)
        capture.accept(buffer, at: origin, source: 0)
        capture.writer.sync {}
        precondition(capture.frames[0] == 480, "pre-pause callbacks must not cross resume")
        capture.writer.sync { capture.commit() }
        let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("capture.json"))) as! [String: Any]
        precondition(snapshot["mic_frames"] as! Int == 480)
        // Inject a closed writer; persisted counts must never claim its failed batch.
        try capture.files[0].close()
        capture.accept(buffer, at: capture.intervalStart + 0.1, source: 0)
        capture.writer.sync {}
        precondition(capture.failure == "capture_disk_error", "disk failure must be explicit")
        await capture.stop()
        print("Synthetic native capture: gap, overlap, pause/resume, durable snapshot and disk failure PASS")
    }
}

// Audio-only capture. Raw tracks and committed counts survive an unfinished WAV.
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

@available(macOS 13.0, *)
// Handle lifecycle is serialized by Rust; callback state uses gate and the writer queue.
final class MeetingCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let directory: URL
    let online: Bool
    let engine = AVAudioEngine()
    var stream: SCStream?
    let gate = NSLock()
    let writer = DispatchQueue(label: "yanyu.meeting.writer")
    let systemQueue = DispatchQueue(label: "yanyu.meeting.system")
    var files: [FileHandle] = []
    var frames = [UInt64(0), 0]
    var pending = [0, 0]
    var origin = 0.0
    var intervalStart = 0.0
    var pausedAt: Double?
    var pausedDuration = 0.0
    var closed = false
    var microphoneTapInstalled = false
    var failure: String?
    var lastCommit = 0.0
    var configurationObserver: NSObjectProtocol?
    var converters: [AVAudioConverter?] = [nil, nil]
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    init(directory: String, online: Bool) throws {
        self.directory = URL(fileURLWithPath: directory); self.online = online
        super.init()
        for name in online ? ["mic.pcm", "system.pcm"] : ["mic.pcm"] {
            let path = self.directory.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw CaptureError.message("capture_disk_error") }
            files.append(try FileHandle(forWritingTo: path))
        }
    }
    static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
    func setFailure(_ message: String) {
        gate.lock(); if failure == nil { failure = message }; gate.unlock()
        writer.async { self.commit() }
    }
    func establishOrigin() { gate.lock(); origin = Self.now(); intervalStart = origin; gate.unlock() }
    func markClosed() -> Bool { gate.lock(); defer { gate.unlock() }; let previous=closed; closed=true; return previous }
    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureError.message("microphone_permission_denied") }
        if online {
            // A display is only an audio content filter. No video output is registered.
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            catch { throw CaptureError.message("system_audio_permission_denied") }
            guard let display = content.displays.first else { throw CaptureError.message("system_audio_unavailable") }
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 16000; configuration.channelCount = 1
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            stream = capture
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { throw CaptureError.message("microphone_unavailable") }
        establishOrigin()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            self.accept(buffer, at: AVAudioTime.seconds(forHostTime: time.hostTime), source: 0)
        }
        microphoneTapInstalled = true
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.gate.lock(); let stopped = self.closed; self.gate.unlock()
            if !stopped { self.setFailure("microphone_interrupted") }
        }
        engine.prepare(); try engine.start()
        if let stream = stream { try await stream.startCapture() }
        writer.sync { commit() }
    }
    func accept(_ buffer: AVAudioPCMBuffer, at host: Double, source: Int) {
        gate.lock()
        guard !closed, pausedAt == nil, failure == nil, host >= intervalStart else { gate.unlock(); return }
        let offset = max(0, Int64(((host - origin - pausedDuration) * 16000).rounded()))
        if converters[source] == nil || converters[source]!.inputFormat != buffer.format {
            converters[source] = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter = converters[source], let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate + 64)) else { gate.unlock(); setFailure("capture_conversion_error"); return }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard result != .error, error == nil, let samples = output.floatChannelData?[0] else { gate.unlock(); setFailure("capture_conversion_error"); return }
        let count = Int(output.frameLength)
        guard pending[source] + count <= 32000 else { gate.unlock(); setFailure("capture_writer_overload"); return }
        let data = Data(bytes: samples, count: count * 4)
        pending[source] += count
        writer.async {
            do {
                let written = Int64(self.frames[source])
                if offset > written {
                    var gap = offset - written
                    let zeros = Data(count: 16384)
                    while gap > 0 { let batch = min(gap, 4096); try self.files[source].write(contentsOf: zeros.prefix(Int(batch)*4)); gap -= batch }
                    self.frames[source] = UInt64(offset)
                }
                let trim = min(Int64(count), max(0, written-offset))
                if trim < count { try self.files[source].write(contentsOf: data.dropFirst(Int(trim)*4)); self.frames[source] += UInt64(Int64(count)-trim) }
                if Self.now() - self.lastCommit >= 1 { self.commit() }
            } catch { self.setFailure("capture_disk_error") }
            self.gate.lock(); self.pending[source] -= count; self.gate.unlock()
        }
        gate.unlock()
    }
    func commit() {
        do {
            for file in files { try file.synchronize() }
            gate.lock(); let error = failure; let paused = pausedAt != nil; gate.unlock()
            var snapshot: [String: Any] = ["mic_frames": frames[0], "system_frames": frames[1], "paused": paused]
            snapshot["error"] = error ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            let temporary = directory.appendingPathComponent("capture.json.tmp")
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            let destination = directory.appendingPathComponent("capture.json")
            if rename(temporary.path, destination.path) != 0 { throw CaptureError.message("capture_disk_error") }
            lastCommit = Self.now()
        } catch {
            gate.lock(); failure = "capture_disk_error"; gate.unlock()
        }
    }
    func pause(_ pause: Bool) throws {
        gate.lock()
        if closed || failure != nil { gate.unlock(); throw CaptureError.message("capture_not_active") }
        let now = Self.now()
        if pause && pausedAt == nil { pausedAt = now }
        if !pause, let beginning = pausedAt { pausedDuration += now-beginning; pausedAt = nil; intervalStart = now }
        gate.unlock()
        writer.sync { commit() }
    }
    func stop() async {
        let wasClosed = markClosed()
        if wasClosed { return }
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }; configurationObserver = nil
        engine.stop(); if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0); microphoneTapInstalled = false }
        if let stream = stream { do { try await stream.stopCapture() } catch { setFailure("system_audio_interrupted") } }
        systemQueue.sync {}
        writer.sync { commit(); for file in files { try? file.close() } }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { setFailure("system_audio_interrupted") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { setFailure("capture_conversion_error"); return }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples), into: pcm.mutableAudioBufferList) == noErr else { setFailure("capture_conversion_error"); return }
        accept(pcm, at: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp), source: 1)
    }
}
enum CaptureError: Error { case message(String) }
private func resultString(_ value: String) -> UnsafeMutablePointer<CChar>? { strdup(value) }
@_cdecl("meeting_available") public func meetingAvailable() -> Int32 { if #available(macOS 13, *) { return 1 }; return 0 }
@_cdecl("meeting_string_free") public func meetingStringFree(_ value: UnsafeMutablePointer<CChar>?) { free(value) }
@_cdecl("meeting_start") public func meetingStart(_ path: UnsafePointer<CChar>, _ online: Int32, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutableRawPointer? {
    guard #available(macOS 13, *) else { error.pointee = resultString("unsupported"); return nil }
    let semaphore = DispatchSemaphore(value: 0)
    var handle: UnsafeMutableRawPointer?
    Task {
        var capture: MeetingCapture?
        do { let instance = try MeetingCapture(directory: String(cString: path), online: online != 0); capture = instance; try await instance.start(); handle = Unmanaged.passRetained(instance).toOpaque() }
        catch let problem { if let capture = capture { await capture.stop() }; if case CaptureError.message(let code) = problem { error.pointee = resultString(code) } else { error.pointee = resultString("capture_start_failed") } }
        semaphore.signal()
    }
    semaphore.wait(); return handle
}
@_cdecl("meeting_pause") public func meetingPause(_ handle: UnsafeMutableRawPointer, _ pause: Int32) -> UnsafeMutablePointer<CChar>? {
    guard #available(macOS 13, *) else { return resultString("unsupported") }
    do { try Unmanaged<MeetingCapture>.fromOpaque(handle).takeUnretainedValue().pause(pause != 0); return nil }
    catch { return resultString("capture_not_active") }
}
@_cdecl("meeting_stop") public func meetingStop(_ handle: UnsafeMutableRawPointer) {
    guard #available(macOS 13, *) else { return }
    let capture = Unmanaged<MeetingCapture>.fromOpaque(handle).takeRetainedValue()
    let semaphore = DispatchSemaphore(value: 0)
    Task { await capture.stop(); semaphore.signal() }; semaphore.wait()
}
@_cdecl("meeting_error") public func meetingError(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    guard #available(macOS 13, *) else { return resultString("unsupported") }
    let capture = Unmanaged<MeetingCapture>.fromOpaque(handle).takeUnretainedValue()
    capture.gate.lock(); defer { capture.gate.unlock() }
    return capture.failure.flatMap { resultString($0) }
}

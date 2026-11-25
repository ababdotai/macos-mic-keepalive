import AVFoundation
import CoreAudio
import AudioToolbox

/// A deliberately conservative prototype: fixed gain and smooth peak compression.
/// No noise gate (which could erase whispered consonants), no recording, no playback to speakers.
func enhancedSample(_ input: Float, gainDB: Float) -> Float {
    guard input.isFinite else { return 0 }
    let amplified = input * pow(10, min(18, max(0, gainDB)) / 20)
    return 0.89 * tanh(amplified / 0.89)
}

final class EnhancementRouter {
    static let destinationUID = "BlackHole2ch_UID"
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat
    private let deviceID: AudioDeviceID
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var queued = 0
    private var generation = 0
    private var failures = 0
    private(set) var retryAt: TimeInterval = 0
    private(set) var error: String?
    let gainDB: Float

    static func destination() throws -> AudioDeviceID {
        var property = SystemAudio.address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { throw failure("BlackHole unavailable") }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices) == noErr,
              let id = devices.first(where: { SystemAudio.uid($0) == destinationUID }) else { throw failure(L("enhance_missing")) }
        return id
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MicEnhancement", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    init(gainDB: Float) throws {
        self.gainDB = gainDB
        let device = try Self.destination()
        self.deviceID = device
        // The capture session must already be running before this graph is bound:
        // starting Bluetooth input can reconfigure the engine's default I/O unit.
        guard let initialFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw Self.failure(L("enhance_failed"))
        }
        format = initialFormat
        engine.attach(player)
        do { try bindOutput() }
        catch {
            // Keep the physical input running while deferred Bluetooth route
            // notifications settle; retry this output on the sample queue.
            resetOutput(); self.error = error.localizedDescription
            failures = 1; retryAt = ProcessInfo.processInfo.systemUptime + 2
        }
    }
    private func currentOutput() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr else { return nil }
        return actual
    }
    private func resetOutput() {
        player.stop(); engine.stop()
        lock.lock(); generation += 1; queued = 0; lock.unlock()
        converter = nil; inputFormat = nil
    }
    /// Repair only the output graph. Do not restart the Bluetooth microphone or
    /// write the system's default route, which would retrigger the mode change.
    private func bindOutput() throws {
        resetOutput()
        guard SystemAudio.uid(deviceID) == Self.destinationUID,
              let unit = engine.outputNode.audioUnit else { throw Self.failure(L("enhance_missing")) }
        var device = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr, currentOutput() == deviceID else { throw Self.failure("\(L("enhance_failed")) (bind: \(status))") }
        // inputFormat is the client-side format, which can still be the
        // previous Bluetooth route (mono/24 kHz). Read the newly bound device's
        // hardware format, then reconnect the graph with that stereo format.
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount == 2,
              let newFormat = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2) else { throw Self.failure(L("enhance_failed") + " (BlackHole format: \(output.sampleRate) Hz, \(output.channelCount) channels)") }
        format = newFormat
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        try engine.start()
        // Starting can itself deliver a deferred reconfiguration. Never queue audio
        // until the post-start route has also been checked.
        guard currentOutput() == deviceID else {
            resetOutput(); throw Self.failure(L("enhance_failed") + " (output route changed)")
        }
        player.play()
    }
    // Called only on the sample queue. Bound queued audio to avoid growing latency.
    func consume(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        if error != nil && now < retryAt { return }
        if error != nil || currentOutput() != deviceID || !engine.isRunning {
            do { try bindOutput(); error = nil; failures = 0; retryAt = 0 }
            catch {
                resetOutput()
                failures += 1
                self.error = error.localizedDescription
                retryAt = now + min(8, pow(2, Double(min(failures, 3))))
                return
            }
        }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let sourceFormat = AVAudioFormat(streamDescription: asbd),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { error = L("enhance_failed") + " (source format)"; return }
        source.frameLength = source.frameCapacity
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(source.frameLength), into: source.mutableAudioBufferList)
        guard copyStatus == noErr else { error = L("enhance_failed") + " (PCM copy: \(copyStatus))"; return }
        if inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: format)
            inputFormat = sourceFormat
        }
        guard let converter else { error = L("enhance_failed") + " (converter unavailable)"; return }
        lock.lock(); let full = queued >= 4; lock.unlock()
        if full { return }
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / sourceFormat.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true; result.pointee = .haveData; return source
        }
        guard status != .error, conversionError == nil else { error = L("enhance_failed") + " (\(conversionError?.localizedDescription ?? "conversion failed"))"; return }
        guard output.frameLength > 0, let channels = output.floatChannelData else { return }
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(output.frameLength) { channels[channel][frame] = enhancedSample(channels[channel][frame], gainDB: gainDB) }
        }
        lock.lock(); queued += 1; let ticket = generation; lock.unlock()
        player.scheduleBuffer(output, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.generation == ticket { self.queued -= 1 }
            self.lock.unlock()
        }
    }
    #if ROUTING_TESTS
    /// Invalidate only this engine's route, with playback stopped. No system route
    /// changes and no test samples may reach the temporary device.
    func invalidateOutputForTesting(_ device: AudioDeviceID) throws {
        resetOutput()
        guard let unit = engine.outputNode.audioUnit else { throw Self.failure("missing output unit") }
        var target = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &target, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Self.failure("test route change: \(status)") }
    }
    var isBoundToDestination: Bool { currentOutput() == deviceID && engine.isRunning }
    #endif
    func stop() { resetOutput() }
}

func runEnhancementTests() {
    assert(enhancedSample(0, gainDB: 12) == 0)
    assert(enhancedSample(.nan, gainDB: 12) == 0)
    let quiet = enhancedSample(0.001, gainDB: 12)
    assert(quiet > 0.0039 && quiet < 0.0041)
    assert(abs(enhancedSample(-0.001, gainDB: 12) + quiet) < 0.000001)
    for gain: Float in [6, 12, 18] {
        var last: Float = -1
        for step in -1000...1000 {
            let output = enhancedSample(Float(step) / 1000, gainDB: gain)
            assert(output.isFinite && abs(output) <= 0.89 && output >= last)
            last = output
        }
    }
    print("PASS: enhancement gain, silence, symmetry, monotonic compression and peak limit")
}

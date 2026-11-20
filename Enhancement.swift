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
    private let format: AVAudioFormat
    private let deviceID: AudioDeviceID
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let lock = NSLock()
    private var queued = 0
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
        var device = try Self.destination()
        self.deviceID = device
        // Bind the output before starting the engine. Never change the default output.
        guard let unit = engine.outputNode.audioUnit else { throw Self.failure(L("enhance_failed")) }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Self.failure("\(L("enhance_failed")) (\(status))") }
        var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr, actual == device else { throw Self.failure(L("enhance_failed")) }
        let output = engine.outputNode.inputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount == 2,
              let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 2) else { throw Self.failure(L("enhance_failed")) }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        try engine.start()
        player.play()
    }
    // Called only on the sample queue. Bound queued audio to avoid growing latency.
    func consume(_ sample: CMSampleBuffer) {
        guard error == nil else { return }
        // CoreAudio can deliver a deferred configuration change after selecting the
        // output device. Resume only if it is STILL the explicitly pinned BlackHole.
        var current: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard let unit = engine.outputNode.audioUnit,
              AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size) == noErr,
              current == deviceID else {
            stop(); error = L("enhance_failed") + " (output route changed)"; return
        }
        if !engine.isRunning {
            let hardware = engine.outputNode.inputFormat(forBus: 0)
            guard hardware.sampleRate == format.sampleRate && hardware.channelCount == format.channelCount else {
                error = L("enhance_failed") + " (output format changed)"; return
            }
            do {
                player.stop(); converter?.reset()
                try engine.start(); player.play()
            } catch { self.error = L("enhance_failed") + " (\(error.localizedDescription))"; return }
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
        lock.lock(); queued += 1; lock.unlock()
        player.scheduleBuffer(output, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }
    func stop() { player.stop(); engine.stop() }
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

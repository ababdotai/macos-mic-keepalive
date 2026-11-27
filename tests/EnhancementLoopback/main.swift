import AVFoundation
import CoreAudio
import Foundation
setbuf(stdout, nil)
// A disconnected or sleeping device can block inside the CoreAudio server.
// Bound this opt-in hardware test instead of leaving it running indefinitely.
DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
    fputs("FAIL: CoreAudio loopback timed out. Check connected devices and retry.\n", stderr)
    exit(2)
}
let destination = try EnhancementRouter.destination()
let originalOutput = SystemAudio.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
let originalInput = SystemAudio.inputUID
var property = SystemAudio.address(kAudioDevicePropertyStreamFormat)
property.mScope = kAudioDevicePropertyScopeInput
var asbd = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
assert(AudioObjectGetPropertyData(destination, &property, 0, nil, &size, &asbd) == noErr)
assert(asbd.mFormatID == kAudioFormatLinearPCM && asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0)
let lock = NSLock()
var peak: Float = 0
var proc: AudioDeviceIOProcID?
assert(AudioDeviceCreateIOProcIDWithBlock(&proc, destination, nil) { _, input, _, _, _ in
    var local: Float = 0
    for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
        guard let data = buffer.mData else { continue }
        let values = data.assumingMemoryBound(to: Float.self)
        for i in 0..<(Int(buffer.mDataByteSize)/4) { local = max(local, abs(values[i])) }
    }
    lock.lock(); peak = max(peak, local); lock.unlock()
} == noErr)
assert(AudioDeviceStart(destination, proc) == noErr)
func sample(rate: Double, offset: Int) -> CMSampleBuffer {
    let count = Int(rate / 100)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: true)!
    var description: CMAudioFormatDescription?
    assert(CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
    var block: CMBlockBuffer?
    assert(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count*4, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count*4, flags: 0, blockBufferOut: &block) == noErr)
    let values = (0..<count).map { Float(sin(2 * Double.pi * 500 * Double(offset + $0) / rate)) * 0.001 }
    values.withUnsafeBytes { assert(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: count*4) == noErr) }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: CMTime(value: Int64(offset), timescale: Int32(rate)), decodeTimeStamp: .invalid)
    var length = 4
    var result: CMSampleBuffer?
    assert(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length, sampleBufferOut: &result) == noErr)
    return result!
}
for rate in [48000.0, 24000.0, 16000.0] {
    let router = try EnhancementRouter(gainDB: 0)
    lock.lock(); peak = 0; lock.unlock()
    for i in 0..<120 {
        router.consume(sample(rate: rate, offset: i * Int(rate/100)))
        Thread.sleep(forTimeInterval: 0.01)
    }
    Thread.sleep(forTimeInterval: 0.1)
    lock.lock(); let baseline = peak; lock.unlock()
    assert(router.error == nil && baseline > 0.0000001, "BlackHole must pass the calibration tone")
    // BlackHole's own volume control may attenuate the signal. Compare against
    // a 0 dB pass through the same route; never overwrite the user's volume.
    router.updateProcessing(gainDB: 12, options: VoiceProcessingOptions())
    lock.lock(); peak = 0; lock.unlock()
    for i in 0..<120 {
        router.consume(sample(rate: rate, offset: i * Int(rate/100)))
        Thread.sleep(forTimeInterval: 0.01)
    }
    Thread.sleep(forTimeInterval: 0.1)
    lock.lock(); let measured = peak; lock.unlock()
    print("BlackHole loopback: input rate=\(rate), 0 dB peak=\(baseline), +12 dB peak=\(measured), ratio=\(measured / baseline), error=\(router.error ?? "none")")
    assert(router.error == nil && measured / baseline > 3.5 && measured / baseline < 4.5)
    #if ROUTING_TESTS
    if let alternate = originalOutput, alternate != destination {
        for cycle in 0..<3 {
            try router.invalidateOutputForTesting(alternate)
            assert(!router.isBoundToDestination)
            lock.lock(); peak = 0; lock.unlock()
            for i in 0..<120 {
                router.consume(sample(rate: rate, offset: i * Int(rate/100)))
                Thread.sleep(forTimeInterval: 0.01)
            }
            lock.lock(); let recovered = peak; lock.unlock()
            assert(router.isBoundToDestination && router.error == nil)
            assert(recovered / baseline > 3.5 && recovered / baseline < 4.5)
            print("PASS: pinned output recovery cycle \(cycle + 1), rate=\(rate), peak=\(recovered)")
        }
    }
    #endif
    // Live DSP changes must preserve the bound route and keep sending samples.
    router.updateProcessing(gainDB: 12, options: VoiceProcessingOptions(noiseReduction: true, voiceClarity: true))
    lock.lock(); peak = 0; lock.unlock()
    for i in 0..<220 {
        router.consume(sample(rate: rate, offset: i * Int(rate/100)))
        Thread.sleep(forTimeInterval: 0.01)
        if i == 110 { lock.lock(); peak = 0; lock.unlock() }
    }
    lock.lock(); let filtered = peak; lock.unlock()
    assert(router.error == nil && filtered / measured > 0.35 && filtered / measured < 1.2)
    print("PASS: denoise + clarity loopback, rate=\(rate), peak=\(filtered)")
    router.stop()
}
AudioDeviceStop(destination, proc)
AudioDeviceDestroyIOProcID(destination, proc!)
assert(SystemAudio.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == originalOutput)
assert(SystemAudio.inputUID == originalInput)
print("PASS: actual BlackHole loopback amplification, resampling, system routes unchanged")

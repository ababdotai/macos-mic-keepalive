import Foundation

func rms(_ values: ArraySlice<Float>) -> Double {
    sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(values.count))
}
func db(_ ratio: Double) -> Double { 20 * log10(max(1e-20, ratio)) }
func tone(_ frequency: Double, rate: Double, seconds: Double = 2, amplitude: Float = 0.001) -> [Float] {
    (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}
func processed(_ input: [Float], rate: Double, options: VoiceProcessingOptions, gain: Float = 0, chunk: Int = 257) -> [Float] {
    let processor = VoiceProcessor(sampleRate: rate, gainDB: gain)
    var output = input
    for offset in stride(from: 0, to: output.count, by: chunk) {
        let count = min(chunk, output.count - offset)
        output.withUnsafeMutableBufferPointer { p in
            processor.process(p.baseAddress! + offset, count: count, gainDB: gain, options: options)
        }
    }
    return output
}

for rate in [16000.0, 24000, 44100, 48000, 96000] {
    // Verify actual sample reconstruction, not just peak or energy preservation.
    let reducer = GentleNoiseReducer(sampleRate: rate)
    let input = tone(723, rate: rate, seconds: 0.3)
    let output = (input + [Float](repeating: 0, count: reducer.size)).map { reducer.process($0) }
    let error = zip(input, output.dropFirst(reducer.size)).map { abs($0 - $1) }.max()!
    assert(error < 1e-7, "Overlap-add reconstruction error: \(error)")
    assert(Double(reducer.size) / rate <= 0.032)

    let shaped = VoiceProcessingOptions(noiseReduction: false, voiceClarity: true)
    func response(_ frequency: Double) -> Double {
        let x = tone(frequency, rate: rate)
        let y = processed(x, rate: rate, options: shaped)
        return db(rms(y.suffix(Int(rate))) / rms(x.suffix(Int(rate))))
    }
    let rumble = response(30), presence = response(2200), consonants = response(6000)
    assert(rumble < -15 && presence > 2.7 && presence < 3.3)
    assert(consonants > -0.5, "Do not cut high-frequency consonants")
    print("EQ \(Int(rate)) Hz: 30 Hz \(String(format: "%.1f", rumble)) dB, 2.2 kHz \(String(format: "%.1f", presence)) dB; delay \(reducer.size) samples")
}

let rate = 48000.0
for gain: Float in [6, 12, 18] {
    let x = tone(700, rate: rate, seconds: 0.1)
    let y = processed(x, rate: rate, options: VoiceProcessingOptions(), gain: gain)
    let delay = VoiceProcessor(sampleRate: rate, gainDB: gain).latencyFrames
    let multiplier = pow(Float(10), gain / 20)
    for i in 0..<(x.count-delay) {
        let expected: Float = 0.89 * tanh(x[i] * multiplier / 0.89)
        assert(abs(y[i+delay] - expected) < 1e-7)
    }
}
// Fixed-seed steady noise; then a quiet, modulated speech-band signal. These
// synthetic measurements test DSP, not real speech recognition accuracy.
var seed: UInt64 = 42
let noise: [Float] = (0..<Int(rate * 4)).map { _ in
    seed = seed &* 6364136223846793005 &+ 1
    return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * 0.0005
}
let denoise = VoiceProcessingOptions(noiseReduction: true, voiceClarity: false)
let cleaned = processed(noise, rate: rate, options: denoise)
let attenuation = db(rms(cleaned.suffix(48000)) / rms(noise.suffix(48000)))
assert(attenuation < -2 && attenuation > -6.2, "Noise attenuation: \(attenuation)")

let voice: [Float] = noise.indices.map { i in
    guard i >= 120000 && i < 144000 else { return 0 }
    let t = Double(i - 120000) / rate
    return Float(0.002 * sin(.pi * t / 0.5) * sin(2 * .pi * 1200 * t))
}
let mixture = zip(noise, voice).map(+)
let improved = processed(mixture, rate: rate, options: denoise)
let latency = GentleNoiseReducer(sampleRate: rate).size
let range = 124800..<139200
let reference = range.map { voice[$0] }
let residual = range.map { improved[$0 + latency] - voice[$0] }
let before = db(rms(reference[...]) / rms(noise[range]))
let after = db(rms(reference[...]) / rms(residual[...]))
assert(after > before + 0.8, "Synthetic SNR did not improve: \(before) -> \(after)")
print("Steady-noise attenuation: \(String(format: "%.2f", attenuation)) dB; synthetic speech-band SNR: \(String(format: "%.2f", before)) -> \(String(format: "%.2f", after)) dB")

// No hard gate: even a very low signal must pass. Test both channels via separate
// processor instances, arbitrary buffer sizes, invalid samples and peak limits.
let tiny = tone(1400, rate: rate, amplitude: 1e-7)
let whisper = processed(tiny, rate: rate, options: denoise)
assert(rms(whisper.suffix(48000)) > rms(tiny.suffix(48000)) * 0.45)
let all = VoiceProcessingOptions(noiseReduction: true, voiceClarity: true)
let block1 = processed(mixture, rate: rate, options: all, chunk: 127)
let block2 = processed(mixture, rate: rate, options: all, chunk: 1024)
assert(zip(block1, block2).allSatisfy { abs($0 - $1) < 1e-7 })
let hostile = [Float.nan, .infinity, -.infinity, 1, -1] + tone(2200, rate: rate, amplitude: 1)
assert(processed(hostile, rate: rate, options: all, gain: 18).allSatisfy { $0.isFinite && abs($0) <= 0.89 })
assert(processed([Float](repeating: 0, count: 48000), rate: rate, options: all).allSatisfy { $0 == 0 })

// Toggle processing and gain while the same stream continues. The filter and
// delay state must remain continuous instead of introducing a new silent gap.
let live = VoiceProcessor(sampleRate: rate, gainDB: 12)
var continuity = tone(1000, rate: rate, seconds: 1)
for offset in stride(from: 0, to: continuity.count, by: 480) {
    let active = offset >= 24000
    continuity.withUnsafeMutableBufferPointer {
        live.process($0.baseAddress! + offset, count: 480, gainDB: active ? 6 : 12, options: active ? all : VoiceProcessingOptions())
    }
}
assert(rms(continuity[24000..<24480]) > 0.0005)
print("PASS: reconstruction, frequency response, gentle noise reduction, quiet-signal passage, chunk invariance, finite/limited output and live changes")

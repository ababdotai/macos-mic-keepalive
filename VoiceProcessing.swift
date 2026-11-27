import Accelerate
import Foundation

struct VoiceProcessingOptions: Equatable {
    // Opt in so existing microphones keep their previous sound after upgrading.
    var noiseReduction = false
    var voiceClarity = false
}

/// Streaming, per-channel DSP. Called exclusively on the capture sample queue.
/// The overlap-add path stays warm even in bypass, allowing live A/B changes
/// without restarting Bluetooth capture or changing the output's latency.
final class VoiceProcessor {
    private let reducer: GentleNoiseReducer
    private var highPass: SpeechBiquad
    private var presence: SpeechBiquad
    private var clarityMix: Float = 0
    private var gain: Float
    private let smoothing: Float
    var latencyFrames: Int { reducer.size }

    init(sampleRate: Double, gainDB: Float) {
        reducer = GentleNoiseReducer(sampleRate: sampleRate)
        highPass = .highPass(sampleRate: sampleRate, frequency: 80)
        presence = .presence(sampleRate: sampleRate, frequency: 2200, gainDB: 3)
        gain = Self.linearGain(gainDB)
        smoothing = Float(1 - exp(-1 / (0.01 * sampleRate)))
    }

    static func linearGain(_ db: Float) -> Float {
        pow(10, min(18, max(0, db.isFinite ? db : 0)) / 20)
    }

    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, gainDB: Float, options: VoiceProcessingOptions) {
        let targetGain = Self.linearGain(gainDB)
        let targetClarity: Float = options.voiceClarity ? 1 : 0
        reducer.enabled = options.noiseReduction
        for frame in 0..<count {
            let raw = samples[frame]
            let input = raw.isFinite ? min(1, max(-1, raw)) : 0
            let reduced = reducer.process(input)
            let shaped = presence.process(highPass.process(reduced))
            clarityMix += smoothing * (targetClarity - clarityMix)
            gain += smoothing * (targetGain - gain)
            let amplified = (reduced + clarityMix * (shaped - reduced)) * gain
            samples[frame] = 0.89 * tanh(amplified / 0.89)
        }
    }
}

/// Second-order Butterworth high-pass and broad +3 dB presence EQ.
/// Do not use a telephone band-pass: whispered consonants need higher frequencies.
/// Coefficients: https://www.w3.org/TR/audio-eq-cookbook/
private struct SpeechBiquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0, z2: Double = 0
    mutating func process(_ input: Float) -> Float {
        let x = Double(input)
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return Float(y)
    }
    static func highPass(sampleRate: Double, frequency: Double) -> Self {
        let w = 2 * Double.pi * frequency / sampleRate
        let c = cos(w), alpha = sin(w) / sqrt(2), a0 = 1 + alpha
        return Self(b0: (1+c)/2/a0, b1: -(1+c)/a0, b2: (1+c)/2/a0, a1: -2*c/a0, a2: (1-alpha)/a0)
    }
    static func presence(sampleRate: Double, frequency: Double, gainDB: Double) -> Self {
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.3) / sampleRate
        let a = pow(10, gainDB / 40), alpha = sin(w) / (2 * 0.7)
        let a0 = 1 + alpha/a
        return Self(b0: (1+alpha*a)/a0, b1: -2*cos(w)/a0, b2: (1-alpha*a)/a0, a1: -2*cos(w)/a0, a2: (1-alpha/a)/a0)
    }
}

/// Conservative minimum-statistics spectral attenuation, not AI speech separation.
/// Square-root Hann windows with 50% overlap reconstruct unity in bypass.
/// Per-bin attenuation never exceeds 6 dB; no voice detector or hard noise gate.
final class GentleNoiseReducer {
    let size: Int
    var enabled = false
    private let hop: Int
    private let logSize: vDSP_Length
    private let fft: FFTSetup
    private let window: [Float]
    private var input: [Float], output: [Float], real: [Float], imaginary: [Float]
    private var power: [Float], smoothed: [Float], minimum: [Float], previousMinimum: [Float], gains: [Float]
    private var cursor = 0, pending = 0, frames = 0, windowFrames = 0
    private let minimumWindow: Int
    private var mix: Float = 0

    init(sampleRate: Double) {
        // About 21 ms at 48 kHz; <= 32 ms at the tested 16–96 kHz rates.
        let exponent = Int(ceil(log2(max(256, min(4096, sampleRate * 0.02)))))
        size = 1 << exponent; hop = size / 2; logSize = vDSP_Length(exponent)
        fft = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2))!
        window = (0..<size).map { Float(sin(Double.pi * Double($0) / Double(1 << exponent))) }
        input = .init(repeating: 0, count: size); output = input; real = input; imaginary = input
        power = .init(repeating: 0, count: size/2 + 1); smoothed = power
        minimum = .init(repeating: .greatestFiniteMagnitude, count: power.count)
        previousMinimum = minimum; gains = .init(repeating: 1, count: power.count)
        minimumWindow = max(1, Int(sampleRate / Double(hop)))
    }
    deinit { vDSP_destroy_fftsetup(fft) }

    func process(_ sample: Float) -> Float {
        let result = output[cursor]
        output[cursor] = 0; input[cursor] = sample
        cursor = (cursor + 1) % size; pending += 1
        if pending == hop { pending = 0; transform() }
        return result
    }

    private func transform() {
        for i in 0..<size { real[i] = input[(cursor + i) % size] * window[i]; imaginary[i] = 0 }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { im in
                var spectrum = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(fft, &spectrum, 1, logSize, FFTDirection(kFFTDirection_Forward))
            }
        }
        for k in power.indices { power[k] = real[k] * real[k] + imaginary[k] * imaginary[k] }
        mix += 0.25 * ((enabled ? 1 : 0) - mix)
        for k in power.indices {
            // Smooth in frequency and time to reduce musical-noise artifacts.
            let p = (power[max(0, k-1)] + 2*power[k] + power[min(size/2, k+1)]) * 0.25
            smoothed[k] = frames == 0 ? p : 0.8 * smoothed[k] + 0.2 * p
            minimum[k] = min(minimum[k], smoothed[k])
            let noise = 1.5 * min(minimum[k], previousMinimum[k])
            let target = sqrt(max(0.25, 1 - noise / max(1e-20, smoothed[k])))
            let speed: Float = target > gains[k] ? 0.6 : 0.1
            gains[k] += speed * (target - gains[k])
            let attenuation = 1 + mix * (gains[k] - 1)
            real[k] *= attenuation; imaginary[k] *= attenuation
            if k > 0 && k < size/2 {
                real[size-k] *= attenuation; imaginary[size-k] *= attenuation
            }
        }
        frames += 1; windowFrames += 1
        if windowFrames == minimumWindow {
            previousMinimum = minimum
            for k in minimum.indices { minimum[k] = .greatestFiniteMagnitude }
            windowFrames = 0
        }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { im in
                var spectrum = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(fft, &spectrum, 1, logSize, FFTDirection(kFFTDirection_Inverse))
            }
        }
        for i in 0..<size { output[(cursor + i) % size] += real[i] * window[i] / Float(size) }
    }
}

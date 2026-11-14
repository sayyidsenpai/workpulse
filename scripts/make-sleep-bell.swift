// Writes the sleep reminder sound: one low, soft bell that fades over 2.5 seconds.
// It is lower and slower than every work chime in Sounds.swift, so "sleep" and "work" sound different.
// Usage: swift scripts/make-sleep-bell.swift Packaging/SleepBell.caf
import AVFoundation

let rate = 44100.0
let length = 2.4
// (frequency in Hz, start in seconds): A3 with a soft E4 a moment later.
let notes: [(Double, Double)] = [(220.00, 0), (329.63, 0.02)]
let harmonic = 0.35
let volume = 0.32
let total = length + 0.12

let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
let frames = AVAudioFrameCount(total * rate)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
let samples = buffer.floatChannelData![0]
for i in 0..<Int(frames) { samples[i] = 0 }
for (frequency, start) in notes {
    let first = Int(start * rate)
    for n in 0..<Int(length * rate) where first + n < Int(frames) {
        let t = Double(n) / rate
        let envelope = min(1, t / 0.02) * exp(-3 * t / length)   // soft attack, long decay
        let wave = sin(2 * .pi * frequency * t) + harmonic * sin(4 * .pi * frequency * t)
        samples[first + n] += Float(wave * envelope * volume / (1 + harmonic))
    }
}

let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "SleepBell.caf")
let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
do {
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
    print("wrote \(url.path)")
} catch {
    FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
}

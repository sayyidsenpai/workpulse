import AVFoundation
import WorkPulseCore

/// Short sine chimes, made in memory (no audio files). Sounds mark only the events that matter:
/// goal reached, end of work hours, and the tracking controls. Never every click.
@MainActor
enum Sounds {
    enum Cue { case up, down, goal, hoursEnded }

    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static var attached = false
    private static var generation = 0

    /// Plays `cue` if the sound setting allows it.
    static func play(_ cue: Cue, mode: SoundMode) {
        switch (mode, cue) {
        case (.off, _), (.goalAndHours, .up), (.goalAndHours, .down): return
        default: play(cue)
        }
    }

    static func play(_ cue: Cue) {
        // (frequency in Hz, start in seconds), length of one note, loudness.
        let (notes, length, volume): ([(Double, Double)], Double, Double) = switch cue {
        case .up: ([(523.25, 0), (659.25, 0.07)], 0.14, 0.16)
        case .down: ([(659.25, 0), (523.25, 0.07)], 0.14, 0.16)
        case .hoursEnded: ([(783.99, 0), (659.25, 0.18), (523.25, 0.36)], 0.45, 0.22)
        case .goal: ([(523.25, 0), (659.25, 0.11), (783.99, 0.22), (1046.5, 0.33)], 0.6, 0.25)
        }
        let rate = 44100.0
        let total = (notes.last?.1 ?? 0) + length + 0.05
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * rate)),
              let samples = buffer.floatChannelData?[0] else { return }
        let frames = Int(total * rate)
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { samples[i] = 0 }
        for (frequency, start) in notes {
            let first = Int(start * rate)
            for n in 0..<Int(length * rate) where first + n < frames {
                let t = Double(n) / rate
                let envelope = min(1, t / 0.015) * exp(-6 * t / length)   // quick attack, soft decay
                samples[first + n] += Float(sin(2 * .pi * frequency * t) * envelope * volume)
            }
        }
        if !attached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            attached = true
        }
        do { if !engine.isRunning { try engine.start() } } catch { return }
        player.scheduleBuffer(buffer)
        player.play()
        // Stop the audio engine when the last chime is over, so an idle app uses no audio power.
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.5) {
            if mine == generation { player.stop(); engine.stop() }
        }
    }
}

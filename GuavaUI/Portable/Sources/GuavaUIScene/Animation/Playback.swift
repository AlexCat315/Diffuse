import Foundation

/// Repetition counts complete cycles. An autoreversing cycle travels out and back.
enum AnimationRepetition: Sendable, Equatable {
    case once
    case count(Int, autoreverses: Bool)
    case forever(autoreverses: Bool)
}

extension Animation {
    struct Playback {
        let time: Float
        let finished: Bool
    }

    func playback(at elapsed: Double) -> Playback {
        let active = max(0, elapsed - delay)
        guard duration > 0 else { return Playback(time: 1, finished: elapsed >= delay) }
        let reversing: Bool, cycles: Double
        switch repetition {
        case .once: return Playback(time: Float(min(1, active / duration)), finished: active >= duration)
        case .count(let count, let autoreverses): reversing = autoreverses; cycles = Double(max(1, count))
        case .forever(let autoreverses): reversing = autoreverses; cycles = .infinity
        }
        let cycleDuration = duration * (reversing ? 2 : 1)
        if active / cycleDuration >= cycles { return Playback(time: reversing ? 0 : 1, finished: true) }
        let position = active.truncatingRemainder(dividingBy: cycleDuration) / duration
        return Playback(time: Float(position <= 1 ? position : 2 - position), finished: false)
    }
}

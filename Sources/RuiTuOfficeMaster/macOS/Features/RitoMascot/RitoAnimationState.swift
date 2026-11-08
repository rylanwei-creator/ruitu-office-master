import Foundation

enum RitoAnimationState: String, Equatable, Sendable, CaseIterable {
    case idle, blinking, thinking, speaking, working, success, error
}

/// Pure frame schedule, shared by rendering and tests. Text generation, never audio, drives speaking.
struct RitoSpriteAnimator {
    struct Frame: Equatable {
        var mouth = 0
        var eyes = 0 // 0 original, 1 closed, 2 thinking, 3 puzzled
        var offset: Double = 0
        var angle: Double = 0
        var decoration: String?
    }
    static let blinkInterval = 4.0
    static let blinkDuration = 0.18
    static let hoverDuration = 0.7
    static let hoverCooldown = 1.2
    static func frame(state: RitoAnimationState, elapsed: Double, reduceMotion: Bool, phase: Double = 0, hoverElapsed: Double? = nil) -> Frame {
        let t = max(0, elapsed)
        var frame = Frame()
        switch state {
        case .idle: break
        case .blinking: frame.eyes = t < 0.18 ? 1 : 0
        case .thinking: frame.eyes = 2; frame.decoration = "…"; frame.angle = -3
        case .speaking:
            let sequence = [0, 1, 2, 1, 0, 1, 2, 2, 1, 0, 1, 0]
            frame.mouth = sequence[Int(t / 0.14) % sequence.count]
        case .working: frame.eyes = 2; frame.decoration = "▤"
        case .success:
            if t < 1.5 { frame.decoration = "✓"; frame.offset = -abs(sin(t * .pi * 2)) * 4 }
        case .error:
            if t < 1.5 { frame.eyes = 3; frame.angle = -5; frame.decoration = "?" }
        }
        if reduceMotion {
            frame.mouth = 0; frame.offset = 0; frame.angle = 0
            if state == .speaking { frame.decoration = "…" }
            return frame
        }
        // Close the calibrated eye sprites once every four seconds.
        if state == .idle || state == .speaking {
            let blinkTime = (t + phase).truncatingRemainder(dividingBy: blinkInterval)
            if blinkTime >= blinkInterval - blinkDuration { frame.eyes = 1 }
        }
        if state == .idle { frame.offset = sin(t * .pi / 2.8) * 2 }
        if state == .speaking { frame.offset = sin(t * 6.5) * 0.9; frame.angle = sin(t * 3.3) * 0.7 }
        if state == .working { frame.offset = sin(t * 3) * 0.8 }
        // A one-shot welcome-page greeting. Generation and task states always take priority.
        if state == .idle, let hoverElapsed, hoverElapsed >= 0, hoverElapsed < hoverDuration {
            let progress = hoverElapsed / hoverDuration
            frame.offset -= sin(progress * .pi) * 9
            frame.angle = sin(progress * .pi * 2) * 2
        }
        return frame
    }
}

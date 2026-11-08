import Foundation
import Observation

@MainActor @Observable
final class RitoAnimationController {
    private(set) var state: RitoAnimationState = .idle
    private(set) var startedAt = Date()
    private(set) var hoverStartedAt: Date?
    let blinkPhase = Double.random(in: 0...2)
    func set(_ state: RitoAnimationState) {
        guard self.state != state else { return }
        self.state = state; startedAt = Date(); hoverStartedAt = nil
    }
    @discardableResult
    func greet(at date: Date = Date()) -> Bool {
        guard state == .idle else { return false }
        if let hoverStartedAt, date.timeIntervalSince(hoverStartedAt) < RitoSpriteAnimator.hoverCooldown { return false }
        hoverStartedAt = date
        return true
    }
    func clearGreeting() { hoverStartedAt = nil }
    func frame(at date: Date, reduceMotion: Bool) -> RitoSpriteAnimator.Frame {
        RitoSpriteAnimator.frame(state: state, elapsed: date.timeIntervalSince(startedAt), reduceMotion: reduceMotion, phase: blinkPhase, hoverElapsed: hoverStartedAt.map { date.timeIntervalSince($0) })
    }
}

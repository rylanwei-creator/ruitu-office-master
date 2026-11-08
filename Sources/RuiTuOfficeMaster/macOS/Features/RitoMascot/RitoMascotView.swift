#if os(macOS)
import SwiftUI

struct RitoMascotView: View {
    var size: CGFloat = 140
    var state: RitoAnimationState = .idle
    var isAnimating = true
    var respondsToHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = RitoAnimationController()
    @State private var appeared = false
    private var playing: Bool { appeared && isAnimating && scenePhase == .active && !reduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !playing)) { timeline in
            let frame = controller.frame(at: timeline.date, reduceMotion: reduceMotion || !playing)
            ZStack(alignment: .topTrailing) {
                if let image = RitoAnimationAssets.image(mouth: frame.mouth, eyes: frame.eyes) {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                } else { Text("Rito 资源缺失").font(.caption2) }
                if let decoration = frame.decoration {
                    Text(decoration).font(.system(size: max(10, size * 0.12), weight: .bold, design: .monospaced))
                        .foregroundStyle(state == .error ? .orange : RToolAIStyle.accent)
                        .padding(2).background(RToolAIStyle.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                }
            }.frame(width: size, height: size)
                .rotationEffect(.degrees(frame.angle)).offset(y: frame.offset * min(1, size / 100))
        }.frame(width: size, height: size).accessibilityElement(children: .ignore).accessibilityLabel("Rito：\(state.rawValue)")
            .task { await RitoAnimationAssets.prepare() }
            .onAppear { appeared = true; controller.set(state) }
            .onDisappear { appeared = false; controller.clearGreeting() }
            .onHover { inside in
                guard inside, respondsToHover, playing, state == .idle else { return }
                controller.greet()
            }
            .onChange(of: playing) { _, active in if !active { controller.clearGreeting() } }
            .onChange(of: state) { _, value in controller.set(value) }
    }
}

#Preview("Rito 动画状态") {
    HStack { ForEach(RitoAnimationState.allCases, id: \.self) { state in VStack { RitoMascotView(size: 100, state: state); Text(state.rawValue) } } }.padding()
}
#endif

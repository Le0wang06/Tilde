import SwiftUI

/// Spinning fan that fires out `~` particles — green while Fan Boost is running.
struct FanWindAnimationView: View {
    var isRunning: Bool

    private var accent: Color { isRunning ? Color(red: 0.22, green: 0.78, blue: 0.38) : .secondary }

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: isRunning ? 1.0 / 60.0 : 1.0, paused: !isRunning)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let degrees = isRunning ? (seconds * 640).truncatingRemainder(dividingBy: 360) : 0
                ZStack {
                    Circle()
                        .fill(accent.opacity(isRunning ? 0.22 : 0.06))
                        .frame(width: 54, height: 54)
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(accent)
                        .rotationEffect(.degrees(degrees))
                }
                .frame(width: 54, height: 54)
            }

            TildeBurstView(isRunning: isRunning, tint: accent)
                .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                .opacity(isRunning ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: isRunning)
        }
        .animation(.easeInOut(duration: 0.2), value: isRunning)
    }
}

/// Streams of `~` characters blown out from the fan.
private struct TildeBurstView: View {
    var isRunning: Bool
    var tint: Color

    private let particleCount = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isRunning)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                guard isRunning else { return }

                for index in 0..<particleCount {
                    let seed = Double(index)
                    let speed = 0.55 + (seed.truncatingRemainder(dividingBy: 5)) * 0.08
                    let phase = seed * 0.17
                    let cycle = (time * speed + phase).truncatingRemainder(dividingBy: 1.15)
                    let progress = CGFloat(cycle / 1.15)

                    let lane = CGFloat(index % 5)
                    let baseY = size.height * (0.12 + lane * 0.18)
                    let wobble = sin((time + seed) * 3.2) * 3.5
                    let x = -8 + progress * (size.width + 20)
                    let y = baseY + wobble
                    let fade = Double(1.0 - progress) * (0.95 - Double(index % 4) * 0.08)
                    let scale = 0.85 + (1.0 - progress) * 0.45
                    let spin = Angle.degrees((time * (50 + seed * 8) + seed * 25).truncatingRemainder(dividingBy: 360))

                    let resolved = context.resolve(
                        Text("~")
                            .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(tint.opacity(max(fade, 0)))
                    )
                    context.drawLayer { layer in
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: spin)
                        layer.draw(resolved, at: .zero, anchor: .center)
                    }

                    if index.isMultiple(of: 3) {
                        let trail = context.resolve(
                            Text("~")
                                .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint.opacity(max(fade * 0.45, 0)))
                        )
                        context.draw(trail, at: CGPoint(x: x - 10, y: y + 1), anchor: .center)
                    }
                }
            }
        }
    }
}

/// Compact switch: vivid green when on, muted gray when off.
struct FanBoostToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn
                          ? Color(red: 0.22, green: 0.78, blue: 0.38)
                          : Color.secondary.opacity(0.28))
                Capsule()
                    .strokeBorder(
                        isOn ? Color.green.opacity(0.55) : Color.secondary.opacity(0.2),
                        lineWidth: 0.5
                    )

                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(isOn ? Color.white.opacity(0.95) : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: isOn ? .leading : .trailing)
                    .padding(.horizontal, 6)

                HStack {
                    if isOn { Spacer(minLength: 0) }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    if !isOn { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 44, height: 22)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

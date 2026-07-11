import SwiftUI

/// Spinning fan with side wind stream — shown when Fan Boost is enabled.
struct FanWindAnimationView: View {
    var isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: isRunning ? 1.0 / 60.0 : 1.0, paused: !isRunning)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let degrees = isRunning ? (seconds * 640).truncatingRemainder(dividingBy: 360) : 0
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(isRunning ? 0.16 : 0.06))
                        .frame(width: 54, height: 54)
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(isRunning ? Color.blue : Color.secondary)
                        .rotationEffect(.degrees(degrees))
                }
                .frame(width: 54, height: 54)
            }

            WindStreamView(isRunning: isRunning)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
        }
        .animation(.easeInOut(duration: 0.2), value: isRunning)
    }
}

private struct WindStreamView: View {
    var isRunning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: isRunning ? 1.0 / 30.0 : 1.0, paused: !isRunning)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let lineCount = 5
                for index in 0..<lineCount {
                    let lag = Double(index) * 0.18
                    let travel = CGFloat((time * (1.35 + Double(index) * 0.12) + lag).truncatingRemainder(dividingBy: 1.2))
                    let y = size.height * (0.18 + CGFloat(index) * 0.16)
                    let startX = -size.width * 0.15 + travel * (size.width * 1.25)
                    let length = size.width * (0.28 + CGFloat(index % 3) * 0.06)
                    var path = Path()
                    let wobble = sin(travel * .pi * 2) * 2
                    path.move(to: CGPoint(x: startX, y: y + wobble))
                    path.addQuadCurve(
                        to: CGPoint(x: startX + length, y: y),
                        control: CGPoint(x: startX + length * 0.5, y: y - 5)
                    )
                    context.stroke(
                        path,
                        with: .color(Color.blue.opacity(isRunning ? 0.55 - Double(index) * 0.07 : 0.12)),
                        style: StrokeStyle(lineWidth: isRunning ? 2 : 1, lineCap: .round)
                    )
                }
            }
        }
        .opacity(isRunning ? 1 : 0.35)
    }
}

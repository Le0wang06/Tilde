import SwiftUI

/// One row of the first-run checklist shown until Tilde has everything it needs.
struct SetupStep: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isDone: Bool
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

/// A compact checklist card. It renders only the steps that are still open plus
/// the ones already completed, so the user sees progress rather than a wall of warnings.
struct SetupCard: View {
    let steps: [SetupStep]
    let notes: [String]

    private var openCount: Int { steps.filter { !$0.isDone }.count }

    var body: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: TildeDesign.Spacing.m) {
                HStack(spacing: TildeDesign.Spacing.s) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("GET SET UP")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: TildeDesign.Spacing.xs)
                    Text("\(steps.count - openCount) of \(steps.count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Setup, \(steps.count - openCount) of \(steps.count) steps complete")

                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: TildeDesign.Spacing.s + 1) {
                        Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(step.isDone ? Color.green : Color.secondary)
                            .frame(width: 14)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(step.isDone ? .secondary : .primary)
                            if !step.isDone {
                                Text(step.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: TildeDesign.Spacing.xs)
                        if !step.isDone, let actionTitle = step.actionTitle, let action = step.action {
                            Button(actionTitle, action: action)
                                .font(.caption2.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("\(actionTitle), \(step.title)")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(step.isDone ? "Done" : "Not done")
                }

                if let note = notes.first {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .help(notes.joined(separator: "\n"))
                }
            }
        }
    }
}

/// Header row for a collapsible panel section. Shows a one-line summary while
/// collapsed so the section still carries information at a glance.
struct SectionDisclosureHeader: View {
    let title: String
    let summary: String
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(TildeDesign.Motion.standard) { isExpanded.toggle() }
            }
        } label: {
            HStack(spacing: TildeDesign.Spacing.s) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if !isExpanded {
                    Text(summary)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: TildeDesign.Spacing.xs)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) details")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed, \(summary)")
        .accessibilityAddTraits(.isButton)
    }
}

import Foundation

/// Formats the always-on menu bar title so price stays primary while
/// attention gets a tiny persistent mark.
public enum MenuBarAttentionTitle {
    public static func compose(spendText: String, needsAttention: Bool) -> String {
        needsAttention ? "! \(spendText)" : spendText
    }
}

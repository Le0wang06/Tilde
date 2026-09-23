import SwiftUI

/// Single source of truth for the panel's spacing, radii, opacities, and frame.
/// Values mirror what the panel already used as literals; centralising them keeps
/// the popover, the status-item controller, and the README capture in agreement.
enum TildeDesign {
    enum Panel {
        static let width: CGFloat = 332
        static let maxHeight: CGFloat = 460
        static let seedHeight: CGFloat = 420
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 10
        static let xl: CGFloat = 12
    }

    enum Radius {
        static let control: CGFloat = 6
        static let button: CGFloat = 8
        static let card: CGFloat = 12
        static let panel: CGFloat = 18
    }

    enum Opacity {
        static let hairline: Double = 0.06
        static let fillSubtle: Double = 0.06
        static let fillMuted: Double = 0.08
        static let tintSoft: Double = 0.12
        static let tintPill: Double = 0.14
        static let tintBadge: Double = 0.16
        static let selected: Double = 0.22
    }

    enum Motion {
        static let quick: Animation = .easeInOut(duration: 0.15)
        static let standard: Animation = .easeInOut(duration: 0.22)
    }
}

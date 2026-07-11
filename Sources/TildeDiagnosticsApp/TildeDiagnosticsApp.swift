import SwiftUI
import TildeCore

@main
struct TildeDiagnosticsApp: App {
    var body: some Scene {
        WindowGroup("Tilde Diagnostics") {
            ContentView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 760, height: 640)
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 36))
            Text("Tilde Phase 0")
                .font(.title)
            Text("Diagnostic providers are being verified.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

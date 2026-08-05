import SwiftUI
import AppKit

/// A floating free-space "widget" pinned at desktop-icon level: visible on the
/// desktop, always behind normal windows, on every Space. (A real WidgetKit
/// extension needs Xcode to build — this is the CLT-friendly equivalent.)
@MainActor
@Observable
final class DesktopWidgetModel {
    static let defaultsKey = "desktopWidgetEnabled"

    private var panel: NSPanel?
    var isVisible = false

    func restoreIfEnabled() {
        guard !AppDelegate.isScheduledRun,
              UserDefaults.standard.bool(forKey: Self.defaultsKey),
              !isVisible else { return }
        show()
    }

    func toggle() {
        isVisible ? hide() : show()
        UserDefaults.standard.set(isVisible, forKey: Self.defaultsKey)
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 170, height: 150),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: DesktopWidgetView())
            let autosave = "ChinchillaDesktopWidget"
            if !panel.setFrameUsingName(autosave) {
                if let screen = NSScreen.main {
                    let frame = screen.visibleFrame
                    panel.setFrameOrigin(NSPoint(x: frame.maxX - 190, y: frame.maxY - 170))
                }
            }
            panel.setFrameAutosaveName(autosave)
            self.panel = panel
        }
        if panel?.contentView == nil {
            panel?.contentView = NSHostingView(rootView: DesktopWidgetView())
        }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    private func hide() {
        panel?.orderOut(nil)
        // Dropping the hosting view is what actually cancels the widget's
        // polling `.task` — orderOut alone left an invisible view refreshing
        // and animating every minute for as long as the app ran. The panel
        // itself stays, so its frame autosave keeps working.
        panel?.contentView = nil
        isVisible = false
    }
}

struct DesktopWidgetView: View {
    @State private var usage = DiskUsage()

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: usage.usedFraction) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: 0) {
                    Text(usage.available, format: .byteCount(style: .file))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text("free")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(gaugeColor)
            .scaleEffect(1.15)
            .frame(height: 78)
            HStack(spacing: 4) {
                Text(verbatim: "🐭")
                    .font(.system(size: 10))
                Text("Purgeable \(Text(usage.purgeable, format: .byteCount(style: .file)))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 170, height: 150)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .task {
            while !Task.isCancelled {
                withAnimation { usage = DiskUsage.current() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var gaugeColor: Color {
        switch usage.usedFraction {
        case ..<0.8: .green
        case ..<0.92: .orange
        default: .red
        }
    }
}

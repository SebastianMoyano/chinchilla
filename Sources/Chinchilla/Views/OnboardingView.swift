import SwiftUI
import AppKit
import SystemKit

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var hasFDA = Permissions.hasFullDiskAccess()

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 20) {
            Group {
                switch step {
                case 0: welcome
                case 1: dailyBoost
                case 2: fullDiskAccess
                case 3: tabSaver
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Color.purple : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step < stepCount - 1 {
                    Button("Continue") { withAnimation { step += 1 } }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                } else {
                    Button("Let's go") {
                        UserDefaults.standard.set(true, forKey: "onboarded")
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Text(verbatim: "🐭✨")
                .font(.system(size: 60))
            Text("Welcome to Chinchilla")
                .font(.title.bold())
            Text("Clean junk, uninstall apps completely, explore your disk, optimize for gaming and keep Docker tidy — all native, all honest.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack(spacing: 18) {
                ForEach([SidebarItem.deepClean, .uninstaller, .diskAnalyzer, .gaming, .devTools]) { item in
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.title2)
                            .foregroundStyle(item.tint)
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var dailyBoost: some View {
        let boost = appState.dailyBoost
        return VStack(spacing: 14) {
            Image(systemName: "bolt.heart.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("How do you use your Mac?")
                .font(.title2.bold())
            Text("If it's your everyday machine (especially with 8 GB of memory), turn this on and forget about it. Chinchilla will sleep background browser tabs, run a safe clean once a week, and give you a gentle heads-up when memory is the reason things feel slow.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Toggle(isOn: Binding(
                get: { boost.isEnabled },
                set: { boost.toggle($0) }
            )) {
                Text("Everyday mode (recommended)")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .tint(.green)
            Text("Gamer too? Gaming Mode lives in the sidebar for when you play. Everything here can be changed later from the Dashboard.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 380)
        }
    }

    private var fullDiskAccess: some View {
        VStack(spacing: 14) {
            Image(systemName: hasFDA ? "lock.open.fill" : "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(hasFDA ? .green : .yellow)
            Text("Full Disk Access")
                .font(.title2.bold())
            if hasFDA {
                Text("Granted — Chinchilla can clean Safari, the Trash and other protected locations.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            } else {
                Text("Optional but recommended: without it, Safari caches, the Trash and some folders can't be measured or cleaned.\n\nAdd Chinchilla with the + button, then come back here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 400)
                HStack {
                    Button("Open System Settings") {
                        if let url = URL(string: Permissions.fullDiskAccessSettingsURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        hasFDA = Permissions.hasFullDiskAccess()
                    } label: {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var tabSaver: some View {
        let model = appState.tabSaver
        return VStack(spacing: 14) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("Too many tabs?")
                .font(.title2.bold())
            Text("Chinchilla can tell your browser to put tabs you're not looking at to sleep: they free their memory and reload when you click them. Nothing closes, nothing is lost — your Mac just breathes easier.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            if model.policyBrowsers.isEmpty {
                Text("No Chromium browser (Chrome, Edge, Brave) detected — you can skip this.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Toggle(isOn: Binding(
                    get: { model.anySaverOn },
                    set: { model.setAllMemorySavers($0) }
                )) {
                    Text("Enable for \(model.policyBrowsers.map(\.browser.name).joined(separator: ", "))")
                }
                .toggleStyle(.switch)
                .tint(.indigo)
                Text("Takes effect after restarting the browser (check chrome://settings/performance — \"Memory Saver\" on). Some Chrome versions may mention \"Managed by your organization\": that's this switch, gone when you turn it off.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 380)
            }
        }
        .onAppear { model.refresh() }
    }

    private var ready: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.title2.bold())
            Text("Nothing is ever deleted without your review, cleans go to the Trash when possible, and every deletion is logged. Start with a Smart Scan from the Dashboard.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
    }
}

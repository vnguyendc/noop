#if os(iOS)
import StrandDesign
import SwiftUI

/// Top of the Apple Health screen on iPhone: connect NOOP to Apple Health, then show that it is
/// connected and when it last synced. Permission is asked only from the button, after saying what
/// NOOP reads and saves.
struct AppleHealthConnectCard: View {
    @ObservedObject var health: HealthKitBridge
    @State private var connecting = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                switch health.connection {
                case .unavailable:
                    Text("Apple Health isn't available on this device.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                case .notConnected:
                    notConnected
                case .connected(let canSave):
                    connected(canSave: canSave)
                }

                if let error = health.lastError {
                    Text(error)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
            }
        }
        .task { await health.refreshAuthorization() }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Apple Health")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("NOOP saves your daily resting heart rate, HRV, blood oxygen and breathing rate to Apple Health, so other apps can use them. It also reads your Health data to fill in this page. Everything stays on your iPhone.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Button {
                connect()
            } label: {
                Label(connecting ? "Connecting…" : "Connect Apple Health", systemImage: "heart.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(connecting)
        }
    }

    private func connected(canSave: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StatePill(canSave ? "Connected to Apple Health" : "Not saving to Apple Health",
                      tone: canSave ? .accent : .warning)
            Text(canSave
                 ? "NOOP saves your daily resting heart rate, HRV, blood oxygen and breathing rate each time you open it."
                 : "To let NOOP save to Apple Health, open Settings → Privacy & Security → Health → NOOP and turn on the data types.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            if health.syncing {
                Text("Syncing…")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if let last = health.lastSync {
                // lastSync is set in this session only (each launch syncs again), so the time is enough.
                Text("Last synced at \(last.formatted(date: .omitted, time: .shortened))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func connect() {
        connecting = true
        Task {
            await health.requestAuthorization()
            await health.sync()
            connecting = false
        }
    }
}
#endif

import SwiftUI

struct WatchGlanceView: View {
    @ObservedObject var live: WatchLiveModel
    @ObservedObject var store: WatchSnapshotStore
    @ObservedObject var directClient: WatchDirectBLEClient
    @ObservedObject var workout: WatchWorkoutController

    private var directState: WatchDirectLiveState { directClient.state }

    var body: some View {
        ScrollView {
            Group {
                if live.isLive {
                    liveView
                } else {
                    glanceView
                }
            }
            .padding(.horizontal, 4)
        }
        .task {
            store.requestRefresh()
            #if DEBUG
            // Simulator checks: `simctl launch <watch> <bundle> -NOOPAutoStartWorkout YES`
            // (or `-NOOPAutoStartLiveOnly YES` to skip the workout session and its Health prompt).
            let defaults = UserDefaults.standard
            if !live.isLive, defaults.bool(forKey: "NOOPAutoStartWorkout") {
                live.start()
            } else if !live.isLive, defaults.bool(forKey: "NOOPAutoStartLiveOnly") {
                live.start(useWorkoutSession: false)
            }
            #endif
        }
        .onReceive(directClient.$state) { state in
            store.applyDirectState(state)
        }
    }

    // MARK: - Glance (data from the phone)

    private var glanceView: some View {
        let snapshot = store.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text("NOOP")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 10) {
                // No label inside the ring: the "Charge" heading beside it names the value.
                Gauge(value: Double(snapshot?.recovery ?? 0), in: 0...100) {
                    EmptyView()
                } currentValueLabel: {
                    Text(snapshot?.recovery.map(String.init) ?? "–")
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .tint(chargeColor(snapshot?.recovery))
                .scaleEffect(1.25)
                .frame(width: 64, height: 64)
                .accessibilityLabel(chargeAccessibilityLabel(snapshot?.recovery))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Charge")
                        .font(.headline)
                    metric(snapshot?.bpm.map { "\($0) bpm" }, systemImage: "heart.fill",
                           accessibility: snapshot?.bpm.map { "Heart rate \($0) beats per minute" })
                    metric(snapshot?.batteryPct.map { "\($0)%" }, systemImage: batterySymbol(snapshot?.batteryPct),
                           accessibility: snapshot?.batteryPct.map { "Strap battery \($0) percent" })
                }
            }

            if let snapshot {
                Text(snapshot.bonded ? "Strap connected to iPhone" : "Strap not connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(snapshot.updatedText())
                    .font(.caption2)
                    .foregroundStyle(snapshot.isStale() ? .orange : .secondary)
            } else {
                Text("Open NOOP on your iPhone to sync.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                live.start()
            } label: {
                Label("Start workout", systemImage: "figure.run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)

            if let reason = live.endReason ?? workout.unavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Live (watch holds the strap)

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 8) {
            elapsedHeader

            if directState.scanning {
                scanningView
            } else if directState.isActive {
                readingView
            } else {
                failedView
            }

            Button(role: .destructive) {
                live.stop()
            } label: {
                Label("End workout", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)   // the app-wide green tint would otherwise hide the destructive role
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var elapsedHeader: some View {
        HStack {
            if let since = workout.startedAt {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.noopAccent)
            } else {
                Text(workout.isActive ? "Starting workout" : "Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.noopAccent)
            }
            Spacer()
        }
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .frame(width: 18, height: 18)
                Text("Looking for your strap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = directState.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            ForEach(directState.discoveredDevices) { device in
                Button {
                    directClient.connect(to: device)
                } label: {
                    Text(device.displayName)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityHint("Connect to this strap")
            }
        }
    }

    /// Bluetooth off, permission missing, or the connection failed. The workout keeps running so
    /// the user can retry, or end it to hand the strap back to the phone.
    private var failedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(directState.errorMessage ?? "Couldn't reach your strap.")
                .font(.caption)
                .foregroundStyle(.orange)
            Button {
                live.rescan()
            } label: {
                Label("Search again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var readingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(connectionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(directState.bpm.map(String.init) ?? "–")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(directState.connected ? Color.primary : Color.secondary)
                Text("bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(directState.bpm.map { "Heart rate \($0) beats per minute" } ?? "No heart rate yet")

            HStack {
                metric(directState.rr.isEmpty ? "No R-R" : "\(directState.rr.count) R-R",
                       systemImage: "waveform.path.ecg",
                       accessibility: directState.rr.isEmpty ? "No R-R intervals" : "\(directState.rr.count) R-R intervals")
                Spacer()
                metric(directState.batteryPct.map { "\($0)%" }, systemImage: batterySymbol(directState.batteryPct),
                       accessibility: directState.batteryPct.map { "Strap battery \($0) percent" })
            }

            if let error = directState.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let reason = workout.unavailableReason {
                Text("Live only while NOOP is open. \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Helpers

    private var connectionText: String {
        let name = directState.selectedDevice?.displayName ?? "strap"
        if directState.connected { return name }
        if directState.connecting { return "Connecting to \(name)" }
        return "Not connected"
    }

    private func metric(_ text: String?, systemImage: String, accessibility: String?) -> some View {
        Label(text ?? "–", systemImage: systemImage)
            .font(.caption2)
            .monospacedDigit()
            .accessibilityLabel(accessibility ?? "Not available")
    }

    private func chargeColor(_ charge: Int?) -> Color {
        guard let charge else { return .secondary }
        return charge >= 67 ? .green : charge >= 34 ? .yellow : .red
    }

    private func chargeAccessibilityLabel(_ charge: Int?) -> String {
        charge.map { "Charge \($0) out of 100" } ?? "Charge not available"
    }

    private func batterySymbol(_ pct: Int?) -> String {
        guard let pct else { return "battery.0percent" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

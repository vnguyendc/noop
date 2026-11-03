import SwiftUI

struct WatchGlanceView: View {
    @ObservedObject var live: WatchLiveModel
    @ObservedObject var store: WatchSnapshotStore
    @ObservedObject var directClient: WatchDirectBLEClient
    @ObservedObject var workout: WatchWorkoutController

    private var directState: WatchDirectLiveState { directClient.state }

    #if DEBUG
    // `-NOOPStartPage 1` opens on Vitals (2: workouts) for simulator screenshots.
    @State private var page = UserDefaults.standard.integer(forKey: "NOOPStartPage")
    #else
    @State private var page = 0
    #endif

    var body: some View {
        Group {
            if live.isLive {
                ScrollView {
                    liveView
                        .padding(.horizontal, 4)
                }
            } else if let saved = live.lastSaved {
                NavigationStack {
                    WatchSavedWorkoutView(saved: saved) { live.dismissSaved() }
                }
            } else {
                pages
            }
        }
        .task {
            store.requestRefresh()
            #if DEBUG
            // Simulator checks: `simctl launch <watch> <bundle> -NOOPAutoStartWorkout YES`
            // (or `-NOOPAutoStartLiveOnly YES` to skip the workout session and its Health prompt).
            // `-NOOPAutoStartKind running` picks the type; the default is Other.
            // `-NOOPDemoSnapshot YES` shows fixed scores; `-NOOPDemoReadings YES` fakes strap readings during a workout and
            // `-NOOPAutoStopAfter 20` ends it after 20 s; `-NOOPDemoSaved YES` shows the saved screen.
            let defaults = UserDefaults.standard
            let kind = defaults.string(forKey: "NOOPAutoStartKind").flatMap(WatchWorkoutKind.init(rawValue:)) ?? .other
            if defaults.bool(forKey: "NOOPDemoSnapshot") { store.useDemoSnapshot() }
            if defaults.bool(forKey: "NOOPDemoSaved") { live.showDemoSaved() }
            if !live.isLive, defaults.bool(forKey: "NOOPAutoStartWorkout") {
                live.start(kind: kind)
            } else if !live.isLive, defaults.bool(forKey: "NOOPAutoStartLiveOnly") {
                live.start(kind: kind, useWorkoutSession: false)
            }
            if live.isLive, defaults.bool(forKey: "NOOPDemoReadings") {
                let stopAfter = defaults.double(forKey: "NOOPAutoStopAfter")
                live.startDemoReadings(stopAfter: stopAfter > 0 ? stopAfter : nil)
            }
            #endif
        }
        .onReceive(directClient.$state) { state in
            store.applyDirectState(state)
        }
    }

    // MARK: - Pages (data from the phone)

    /// Today, Vitals, Start a workout: turn the Crown or swipe vertically to move between them.
    private var pages: some View {
        NavigationStack {
            TabView(selection: $page) {
                WatchTodayPage(snapshot: store.snapshot, notice: live.endReason ?? workout.unavailableReason)
                    .tag(0)
                WatchVitalsPage(snapshot: store.snapshot)
                    .tag(1)
                WatchWorkoutsPage(lastUsed: live.lastUsedKind) { kind in
                    live.start(kind: kind)
                }
                .tag(2)
            }
            .tabViewStyle(.verticalPage)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(live.activeKind?.name ?? "Workout")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.noopAccent)
                .lineLimit(1)
            if let since = workout.startedAt {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(WatchScoreColor.timer)
            } else {
                Text(workout.isActive ? "Starting" : "Live")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WatchScoreColor.timer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Only worth a line while it says something other than "connected".
            if !directState.connected {
                Text(connectionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
                metric(directState.batteryPct.map { "\($0)%" }, systemImage: batterySymbol(directState.batteryPct),
                       accessibility: directState.batteryPct.map { "Strap battery \($0) percent" })
                Spacer()
                // The R-R count rises while readings flow in: a sign the strap is still talking.
                Text(directState.rr.isEmpty ? "Waiting for readings" : "Recording, \(directState.rr.count) beats")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(directState.rr.isEmpty ? "Waiting for readings" : "Recording, \(directState.rr.count) beats received")
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

}

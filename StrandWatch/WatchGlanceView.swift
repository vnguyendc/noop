import SwiftUI

struct WatchGlanceView: View {
    @ObservedObject var store: WatchSnapshotStore
    @ObservedObject var directClient: WatchDirectBLEClient

    private var snapshot: WatchSnapshot { store.snapshot ?? .placeholder }
    private var directState: WatchDirectLiveState { directClient.state }

    var body: some View {
        ScrollView {
            Group {
                if directState.isActive {
                    directLiveView
                } else {
                    snapshotView
                }
            }
            .padding()
        }
        .task {
            store.requestRefresh()
        }
        .onReceive(directClient.$state) { state in
            store.applyDirectState(state)
        }
    }

    private var recoveryColor: Color {
        guard let recovery = snapshot.recovery else { return .secondary }
        return recovery >= 67 ? .green : recovery >= 34 ? .yellow : .red
    }

    private var snapshotView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(connected: snapshot.bonded)

            Gauge(value: Double(snapshot.recovery ?? 0), in: 0...100) {
                Text("Recovery")
            } currentValueLabel: {
                Text(snapshot.recovery.map(String.init) ?? "-")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(recoveryColor)
            .frame(maxWidth: .infinity)

            HStack {
                Label(snapshot.bpm.map { "\($0)" } ?? "-", systemImage: "waveform.path.ecg")
                Spacer()
                Label(snapshot.batteryPct.map { "\($0)%" } ?? "-", systemImage: "battery.50")
            }
            .font(.caption)

            Text(snapshot.bonded ? "Strap connected" : "Strap offline")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(snapshot.updatedText())
                .font(.caption2)
                .foregroundStyle(snapshot.isStale() ? .orange : .secondary)

            Button {
                store.setDirectModeActive(true)
                directClient.startScan()
            } label: {
                Label("Start Live", systemImage: "dot.radiowaves.left.and.right")
            }
        }
    }

    private var directLiveView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(connected: directState.connected)

            if directState.scanning {
                scanningView
            } else {
                connectedView
            }

            Button(role: .destructive) {
                directClient.stop()
                store.setDirectModeActive(false)
                store.requestRefresh()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView()
                Text("Scanning")
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
                    HStack {
                        Text(device.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text("\(device.rssi)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var connectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connectionText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline) {
                Text(directState.bpm.map(String.init) ?? "-")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                Text("bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(directState.rr.isEmpty ? "No R-R" : "\(directState.rr.count) R-R", systemImage: "waveform.path.ecg")
                Spacer()
                Label(directState.batteryPct.map { "\($0)%" } ?? "-", systemImage: "battery.50")
            }
            .font(.caption2)

            if let error = directState.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var connectionText: String {
        if directState.connected {
            return directState.selectedDevice.map { "Connected to \($0.displayName)" } ?? "Connected"
        }
        if directState.connecting {
            return directState.selectedDevice.map { "Connecting to \($0.displayName)" } ?? "Connecting"
        }
        return "Live mode"
    }

    private func header(connected: Bool) -> some View {
        HStack {
            Text("NOOP")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(connected ? .green : .red)
                .frame(width: 8, height: 8)
        }
    }
}

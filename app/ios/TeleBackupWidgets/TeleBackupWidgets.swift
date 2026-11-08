import WidgetKit
import SwiftUI
import ActivityKit

@main
struct TeleBackupWidgets: WidgetBundle {
    var body: some Widget { BackupLiveActivity() }
}

private func fraction(_ s: BackupAttributes.ContentState) -> Double { s.total > 0 ? min(1, Double(s.done) / Double(s.total)) : 0 }
@ViewBuilder private func controlButton(_ s: BackupAttributes.ContentState) -> some View {
    if #available(iOS 17.0, *) {
        Button(intent: BackupControlIntent(pause: !s.paused)) {
            Label(s.paused ? "Resume" : "Pause", systemImage: s.paused ? "play.fill" : "pause.fill").font(.subheadline.bold())
        }
        .buttonStyle(.bordered).tint(s.paused ? .green : .orange)
    }
}

private func count(_ s: BackupAttributes.ContentState) -> String { "\(s.done) / \(s.total)" }

struct BackupLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BackupAttributes.self) { context in
            // lock screen and banner
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("teleBackup", systemImage: "icloud.and.arrow.up.fill").font(.headline)
                    Spacer()
                    Text(count(context.state)).font(.title3.monospacedDigit().bold())
                }
                ProgressView(value: fraction(context.state)).tint(.blue)
                Text(context.isStale ? "Count updates when iOS wakes teleBackup. Open the app to refresh." : context.state.current).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                controlButton(context.state)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "icloud.and.arrow.up.fill").font(.title2).foregroundStyle(.blue) }
                DynamicIslandExpandedRegion(.trailing) { Text(count(context.state)).font(.title3.monospacedDigit().bold()) }
                DynamicIslandExpandedRegion(.center) { Text("Backing up").font(.headline) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: fraction(context.state)).tint(.blue)
                        Text(context.isStale ? "Open the app to refresh the count" : context.state.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        controlButton(context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "icloud.and.arrow.up.fill").foregroundStyle(.blue)
            } compactTrailing: {
                Text(count(context.state)).font(.caption2.monospacedDigit())
            } minimal: {
                Text("\(context.state.done)").font(.caption2.monospacedDigit())
            }
        }
    }
}

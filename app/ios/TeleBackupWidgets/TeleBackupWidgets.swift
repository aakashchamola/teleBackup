import WidgetKit
import SwiftUI
import ActivityKit

@main
struct TeleBackupWidgets: WidgetBundle {
    var body: some Widget { BackupLiveActivity() }
}

private func fraction(_ s: BackupAttributes.ContentState) -> Double { s.total > 0 ? min(1, Double(s.done) / Double(s.total)) : 0 }
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
                Text(context.state.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                        Text(context.state.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

import SwiftUI
import ThunerCore

/// The per-source switches in Settings (Scrobble from, Notify for): one toggle per source, AirPlay senders
/// indented under the "AirPlay" switch they follow, with a note on the ones that override it.
struct SourceSwitchList: View {
    var rows: [SourceSwitches.Row]
    var switches: SourceSwitches
    var set: (String, Bool) -> Void

    var body: some View {
        ForEach(rows, id: \.name) { row in
            Toggle(isOn: Binding(get: { switches.allows(row.name) }, set: { set(row.name, $0) })) {
                HStack(spacing: 6) {
                    Text(row.name)
                    if row.isGroup {
                        Text("every sender").font(.caption).foregroundStyle(.secondary)
                    } else if let group = row.group {
                        Text(switches.overrides(row.name) ? "its own setting" : "follows \(group)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, row.group == nil ? 0 : 20)
        }
    }
}

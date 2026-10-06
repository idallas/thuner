import AppKit
import SwiftUI

struct AboutView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)

            VStack(spacing: 4) {
                Wordmark().font(.system(size: 26))
                Text("Version \(model.updater.currentVersion)")
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Knows what's playing, from the turntable or anywhere else, and puts the cover on your Tuneshine.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Check for Updates…") { model.updater.checkForUpdates() }
                Link("Website", destination: URL(string: "https://idallas.com/software/thuner/")!)
                    .buttonStyle(.bordered)
            }

            Divider()

            VStack(spacing: 3) {
                Text("Made by Dallas").font(.footnote.weight(.medium))
                Text("Song recognition by ShazamKit · Updates by Sparkle · Artwork from Apple Music and Spotify")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

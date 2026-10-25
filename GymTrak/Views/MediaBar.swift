import SwiftUI

/// Spotify controls docked above the bottom bar on the workout screen.
/// No client ID: one disabled row. Not connected: Connect. Connected: track, play/pause, skip.
struct MediaBar: View {
    @Environment(Spotify.self) private var spotify
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        Group {
            if !spotify.configured {
                Label("Spotify: add client ID", systemImage: "music.note")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !spotify.connected {
                HStack {
                    Label("Spotify", systemImage: "music.note").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Connect") { Task { await spotify.connect { try await webAuth.authenticate(using: $0, callbackURLScheme: $1) } } }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
            } else {
                connectedRow
                    .task {
                        // Poll only while this bar is on screen; the task is cancelled when it leaves.
                        while !Task.isCancelled {
                            await spotify.refresh()
                            try? await Task.sleep(for: .seconds(3))
                        }
                    }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(.bar)
    }

    private var connectedRow: some View {
        let pb = spotify.playback
        let error = spotify.lastError
        return HStack(spacing: 12) {
            AsyncImage(url: pb?.artURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.tertiarySystemFill)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(error ?? pb?.track ?? "Nothing playing")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(error == nil ? .primary : Theme.warning)
                if error == nil, let artist = pb?.artist, !artist.isEmpty {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { Task { await spotify.previous() } } label: {
                Image(systemName: "backward.fill").accessibilityLabel("Previous track")
            }
            Button { Task { await spotify.playPause() } } label: {
                Image(systemName: (pb?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    .accessibilityLabel((pb?.isPlaying ?? false) ? "Pause" : "Play")
            }
            Button { Task { await spotify.next() } } label: {
                Image(systemName: "forward.fill").accessibilityLabel("Next track")
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .tint(Theme.lift)
    }
}

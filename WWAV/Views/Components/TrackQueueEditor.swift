import SwiftUI

struct TrackQueueEditor: View {
    let title: String
    let emptyMessage: String
    let tracks: [Track]
    @Binding var selectedIDs: [UUID]

    @Environment(\.theme) private var theme

    private var selectedTracks: [Track] {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return selectedIDs.compactMap { byID[$0] }
    }

    private var availableTracks: [Track] {
        let selected = Set(selectedIDs)
        return tracks.filter { !selected.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).wwavLabel(size: 10, tracking: 2)
                Spacer()
                Text("\(selectedTracks.count)")
                    .font(.wwav(11, weight: .light))
                    .tracking(1)
                    .foregroundStyle(theme.muted)
            }

            if selectedTracks.isEmpty {
                Text(emptyMessage)
                    .font(.wwav(13, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(boxBg)
                    .overlay(boxStroke)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selectedTracks.enumerated()), id: \.element.id) { index, track in
                        TrackQueueRow(
                            track: track,
                            index: index + 1,
                            trailing: {
                                queueControls(for: track, at: index)
                            }
                        )
                        if index < selectedTracks.count - 1 { divider }
                    }
                }
                .background(boxBg)
                .overlay(boxStroke)
            }

            if !availableTracks.isEmpty {
                Text("add songs")
                    .wwavLabel(size: 9, tracking: 1.8)
                    .foregroundStyle(theme.muted)
                    .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(Array(availableTracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            selectedIDs.append(track.id)
                        } label: {
                            TrackQueueRow(
                                track: track,
                                index: nil,
                                trailing: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(theme.glow)
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(theme.accent))
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        if index < availableTracks.count - 1 { divider }
                    }
                }
                .background(boxBg)
                .overlay(boxStroke)
            }
        }
    }

    private func queueControls(for track: Track, at index: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                move(track.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .disabled(index == 0)
            .opacity(index == 0 ? 0.28 : 1)

            Button {
                move(track.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .disabled(index >= selectedIDs.count - 1)
            .opacity(index >= selectedIDs.count - 1 ? 0.28 : 1)

            Button(role: .destructive) {
                selectedIDs.removeAll { $0 == track.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
        }
        .foregroundStyle(theme.muted)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.muted.opacity(0.14))
            .frame(height: 1)
            .padding(.leading, 58)
    }

    private var boxBg: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.sand.opacity(0.62))
    }

    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let from = selectedIDs.firstIndex(of: id) else { return }
        let to = max(0, min(selectedIDs.count - 1, from + delta))
        guard from != to else { return }
        let value = selectedIDs.remove(at: from)
        selectedIDs.insert(value, at: to)
    }
}

private struct TrackQueueRow<Trailing: View>: View {
    let track: Track
    let index: Int?
    let trailing: () -> Trailing

    @Environment(\.theme) private var theme

    init(
        track: Track,
        index: Int?,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.track = track
        self.index = index
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.muted.opacity(0.22), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let index {
                        Text(String(format: "%02d", index))
                            .font(.wwav(10, weight: .light))
                            .foregroundStyle(theme.muted)
                    }
                    Text(track.title)
                        .font(.wwav(14, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                }
                Text("@\(track.handle) · \(formatDuration(track.durationSeconds))")
                    .font(.wwav(10, weight: .light))
                    .tracking(1)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
            trailing()
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        ZStack {
            LinearGradient(
                colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
        }
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        guard seconds > 0 else { return "song" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

import SwiftUI

/// The host-side control surface shown when a radio session is live.
///
/// Features:
///   - Mic VU meter (bar graph driven by `broadcaster.talkLevel`).
///   - Status pill ("talking" / "playing: <title>").
///   - Queue list with thumbnails and "play now" buttons.
///   - "back to live" button (only in song mode).
///   - "end live" button.
struct DJConsoleView: View {
    @ObservedObject var broadcaster: LiveRadioBroadcaster
    let session: RadioSession
    let queueTracks: [Track]
    let onEndLive: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: TrackLibrary
    @State private var preparingTrackID: UUID?
    @State private var queueError: String?

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        vuMeter
                        statusPill
                        messagesSection
                        queueSection
                        if let queueError {
                            Text(queueError)
                                .font(.wwav(12, weight: .light, italic: true))
                                .foregroundStyle(Color.red.opacity(0.72))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 120)
                }
            }

            // Floating controls pinned to bottom
            VStack {
                Spacer()
                bottomControls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: 12) {
            // Live pulse indicator
            LivePulseDot()
                .frame(width: 10, height: 10)
            Text("on air")
                .font(.wwav(11, weight: .medium, italic: true))
                .tracking(2)
                .foregroundStyle(theme.glow)
            Spacer()
            Text(session.title)
                .font(.wwav(15, weight: .light, italic: true))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.glow)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.ink.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(theme.accent.opacity(0.85))
        )
    }

    // MARK: – VU meter

    private var vuMeter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("mic level").wwavLabel(size: 10, tracking: 2)
            MicVUMeter(level: broadcaster.talkLevel)
                .frame(height: 28)
        }
        .padding(14)
        .background(boxBg)
        .overlay(boxStroke)
    }

    // MARK: – Status pill

    private var statusPill: some View {
        let isTalking: Bool
        let label: String
        switch broadcaster.mode {
        case .talk:
            isTalking = broadcaster.talkLevel > 0.03
            label = isTalking ? "talking" : "silence"
        case .song(let track):
            isTalking = false
            label = "playing: \(track.title)"
        }

        return HStack(spacing: 8) {
            Circle()
                .fill(isTalking ? theme.accent : (broadcaster.mode == .talk ? theme.muted.opacity(0.4) : Color.green))
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.15), value: isTalking)
            Text(label)
                .font(.wwav(13, weight: .medium, italic: true))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(theme.sand.opacity(0.66)))
        .overlay(Capsule().stroke(theme.muted.opacity(0.20), lineWidth: 1))
    }

    // MARK: – Messages

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("listener messages").wwavLabel(size: 10, tracking: 2)
                Spacer()
                Text("\(broadcaster.messages.count)")
                    .font(.wwav(10, weight: .light))
                    .foregroundStyle(theme.muted)
            }

            if broadcaster.messages.isEmpty {
                Text("messages from listeners will land here while you're live.")
                    .font(.wwav(12, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(boxBg)
                    .overlay(boxStroke)
            } else {
                let recentMessages = Array(broadcaster.messages.suffix(6))
                VStack(spacing: 0) {
                    ForEach(Array(recentMessages.enumerated()), id: \.element.id) { index, message in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(message.senderHandle.isEmpty ? message.senderName : "@\(message.senderHandle)")
                                .font(.wwav(10, weight: .medium))
                                .tracking(1)
                                .foregroundStyle(theme.muted)
                            Text(message.text)
                                .font(.wwav(13, weight: .light))
                                .foregroundStyle(theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        if index < recentMessages.count - 1 {
                            Rectangle()
                                .fill(theme.muted.opacity(0.14))
                                .frame(height: 1)
                        }
                    }
                }
                .background(boxBg)
                .overlay(boxStroke)
            }
        }
    }

    // MARK: – Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("queue").wwavLabel(size: 10, tracking: 2)
            if queueTracks.isEmpty {
                Text("no songs in queue")
                    .font(.wwav(13, weight: .light, italic: true))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(boxBg)
                    .overlay(boxStroke)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(queueTracks.enumerated()), id: \.element.id) { index, track in
                        DJQueueRow(
                            track: track,
                            index: index + 1,
                            isPreparing: preparingTrackID == track.id,
                            isPlaying: {
                                if case .song(let t) = broadcaster.mode { return t.id == track.id }
                                return false
                            }()
                        ) {
                            Task {
                                await playQueuedTrack(track)
                            }
                        }
                        if index < queueTracks.count - 1 {
                            Rectangle()
                                .fill(theme.muted.opacity(0.14))
                                .frame(height: 1)
                                .padding(.leading, 58)
                        }
                    }
                }
                .background(boxBg)
                .overlay(boxStroke)
            }
        }
    }

    // MARK: – Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 10) {
            if case .song = broadcaster.mode {
                Button {
                    broadcaster.returnToTalk()
                } label: {
                    Text("back to live")
                        .font(.wwav(14, weight: .regular, italic: true))
                        .tracking(1.8)
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(theme.sand.opacity(0.8)))
                        .overlay(Capsule().stroke(theme.muted.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                onEndLive()
                dismiss()
            } label: {
                Text("end live")
                    .font(.wwav(15, weight: .regular, italic: true))
                    .tracking(2)
                    .foregroundStyle(theme.glow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [theme.clay, theme.clayDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
            }
            .buttonStyle(.plain)
        }
        .animation(.easeInOut(duration: 0.2), value: {
            if case .song = broadcaster.mode { return true }
            return false
        }())
    }

    // MARK: – Common shapes

    private var boxBg: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.sand.opacity(0.64))
    }

    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
    }

    private func playQueuedTrack(_ track: Track) async {
        guard preparingTrackID == nil else { return }
        queueError = nil
        preparingTrackID = track.id
        library.setRadioCurrentTrack(id: session.id, trackId: track.id)
        let primed = await library.prepareForPlayback(track)
        guard let primed else {
            preparingTrackID = nil
            queueError = "couldn't load stems for \(track.title). try another song."
            return
        }
        if broadcaster.playSong(primed) {
            library.incrementPlays(of: primed.id)
        } else {
            queueError = "\(primed.title) isn't ready for radio playback yet."
        }
        preparingTrackID = nil
    }
}

// MARK: – DJQueueRow

private struct DJQueueRow: View {
    let track: Track
    let index: Int
    let isPreparing: Bool
    let isPlaying: Bool
    let onPlayNow: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            ZStack {
                LinearGradient(
                    colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                CachedAsyncImage(url: track.thumbnailURL) { Color.clear }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.muted.opacity(0.22), lineWidth: 1)
            )

            // Metadata
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(String(format: "%02d", index))
                        .font(.wwav(10, weight: .light))
                        .foregroundStyle(theme.muted)
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

            // Play Now button
            Button {
                onPlayNow()
            } label: {
                ZStack {
                    if isPreparing {
                        Circle().fill(theme.sand.opacity(0.86))
                        ProgressView()
                            .tint(theme.accent)
                            .scaleEffect(0.72)
                    } else if isPlaying {
                        Circle().fill(theme.clayDeep)
                        // Small equalizer icon when playing
                        Image(systemName: "waveform")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.glow)
                    } else {
                        Circle().fill(theme.accent)
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.glow)
                            .offset(x: 1)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(isPlaying || isPreparing)
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        guard seconds > 0 else { return "song" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: – MicVUMeter

/// Horizontal bar graph VU meter for the DJ Console.
struct MicVUMeter: View {
    var level: Float  // 0…1
    var barCount: Int = 20

    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 3
            let totalSpacing = spacing * CGFloat(barCount - 1)
            let barWidth = (geo.size.width - totalSpacing) / CGFloat(barCount)

            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let threshold = Float(i + 1) / Float(barCount)
                    let isLit = Float(level) >= threshold

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isLit ? barColor(for: threshold) : theme.muted.opacity(0.18))
                        .frame(width: barWidth)
                        .animation(.easeOut(duration: 0.06), value: isLit)
                }
            }
        }
    }

    private func barColor(for threshold: Float) -> Color {
        // Green → yellow → red gradient along the meter.
        if threshold < 0.6 { return Color(red: 0.2, green: 0.78, blue: 0.42) }
        if threshold < 0.85 { return Color(red: 0.95, green: 0.82, blue: 0.12) }
        return Color(red: 0.92, green: 0.28, blue: 0.22)
    }
}

// MARK: – LivePulseDot

/// Animated red dot indicating an active broadcast.
private struct LivePulseDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.35))
                .scaleEffect(pulsing ? 2.0 : 1.0)
                .opacity(pulsing ? 0 : 0.7)
            Circle()
                .fill(Color.red)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

// MARK: – LiveTalkVisualizer (used in PlayView listener mode)

/// Radial pulse visualizer driven by incoming talk amplitude.
/// Shown in PlayView when the listener is in "talk state".
struct LiveTalkVisualizer: View {
    var level: Float  // 0…1 from LiveRadioListener.talkLevel
    var sessionTitle: String

    @Environment(\.theme) private var theme
    @State private var animPhase: Double = 0

    private let ringCount = 3

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let baseRadius = min(geo.size.width, geo.size.height) * 0.22

            ZStack {
                // Pulsing rings
                ForEach(0..<ringCount, id: \.self) { i in
                    let delay = Double(i) * 0.33
                    let scale = 1.0 + CGFloat(level) * CGFloat(1.4 + Double(i) * 0.5)
                    Circle()
                        .stroke(
                            theme.accent.opacity(0.35 - Double(i) * 0.08),
                            lineWidth: 1.5
                        )
                        .frame(
                            width: baseRadius * 2 * scale,
                            height: baseRadius * 2 * scale
                        )
                        .position(center)
                        .animation(
                            .easeOut(duration: 0.12).delay(delay * 0.04),
                            value: level
                        )
                }

                // Centre dot
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accent, theme.clayDeep],
                            center: .center,
                            startRadius: 1,
                            endRadius: baseRadius
                        )
                    )
                    .frame(width: baseRadius * 2, height: baseRadius * 2)
                    .position(center)

                // Live / talking label
                VStack(spacing: 6) {
                    LivePulseDot()
                        .frame(width: 9, height: 9)
                    Text(sessionTitle.isEmpty ? "live" : sessionTitle)
                        .wwavTitle(size: 18)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                    Text("talking")
                        .font(.wwav(11, weight: .light, italic: true))
                        .tracking(2)
                        .foregroundStyle(theme.muted)
                        .opacity(level > 0.03 ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: level > 0.03)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

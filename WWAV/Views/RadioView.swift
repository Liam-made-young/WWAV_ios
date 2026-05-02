import SwiftUI

struct RadioView: View {
    @EnvironmentObject var library: TrackLibrary
    @EnvironmentObject var player: StemPlayerEngine
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var broadcaster: LiveRadioBroadcaster
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.theme) private var theme

    @State private var sessionId: UUID?
    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var queueTrackIds: [UUID] = []
    @State private var savedAt: Date?
    @State private var showingDJConsole = false

    private var mySession: RadioSession? {
        if let sessionId,
           let session = library.radioSessions.first(where: { $0.id == sessionId }) {
            return session
        }
        return library.radioSessions.first { session in
            normalize(session.hostHandle) == normalize(library.profile.handle)
        }
    }

    private var currentTrack: Track? {
        guard let mySession else { return nil }
        return library.currentTrack(for: mySession)
    }

    var body: some View {
        ZStack {
            theme.pageRadial.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if library.albumCandidateTracks.isEmpty {
                        emptyLibrary
                    } else {
                        if let mySession, mySession.isLive {
                            onAirCard(mySession)
                        }

                        fields

                        TrackQueueEditor(
                            title: "queue playlist",
                            emptyMessage: "add songs to queue before going live",
                            tracks: library.albumCandidateTracks,
                            selectedIDs: $queueTrackIds
                        )

                        controls
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .onAppear { hydrateFromSession() }
        .sheet(isPresented: $showingDJConsole, onDismiss: {
            // If the broadcaster was stopped from inside the console, sync.
            if !broadcaster.isLive, let session = mySession, session.isLive {
                library.stopRadio(id: session.id)
                hydrateFromSession()
            }
        }) {
            if let session = mySession {
                DJConsoleView(
                    broadcaster: broadcaster,
                    session: session,
                    queueTracks: library.tracks(for: session),
                    onEndLive: {
                        broadcaster.endLive()
                        library.stopRadio(id: session.id)
                        hydrateFromSession()
                    }
                )
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(nav)
                .environmentObject(themeManager)
                .environment(\.theme, themeManager.palette)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RadioPulseMark()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text("radio").wwavTitle(size: 42)
                Text("audio-only live queue")
                    .font(.wwav(11, weight: .light))
                    .tracking(1.5)
                    .foregroundStyle(theme.muted)
            }
            Spacer()
            if mySession?.isLive == true {
                Text("on air")
                    .font(.wwav(10, weight: .medium, italic: true))
                    .tracking(1.5)
                    .foregroundStyle(theme.glow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.accent))
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("no songs ready")
                .wwavTitle(size: 24)
            Text("upload music first, then build a radio queue from those songs.")
                .font(.wwav(14, weight: .light, italic: true))
                .foregroundStyle(theme.muted)
            Button {
                nav.compose(.music)
            } label: {
                Text("upload music")
                    .font(.wwav(13, weight: .medium, italic: true))
                    .tracking(1.4)
                    .foregroundStyle(theme.glow)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(16)
        .background(boxBg)
        .overlay(boxStroke)
    }

    private func onAirCard(_ session: RadioSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("live now").wwavLabel(size: 10, tracking: 2)
            if let currentTrack {
                HStack(spacing: 12) {
                    ZStack {
                        LinearGradient(
                            colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        CachedAsyncImage(url: currentTrack.thumbnailURL) { Color.clear }
                    }
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.muted.opacity(0.22), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentTrack.title)
                            .wwavTitle(size: 23)
                            .lineLimit(1)
                        Text("@\(currentTrack.handle) · \(session.queueTrackIds.count) in queue")
                            .font(.wwav(11, weight: .light))
                            .tracking(1)
                            .foregroundStyle(theme.muted)
                    }

                    Spacer(minLength: 0)
                    Button {
                        nav.openPost(currentTrack, in: library, with: player)
                    } label: {
                        ZStack {
                            Circle().fill(theme.accent)
                            Triangle().fill(theme.glow).frame(width: 9, height: 11).offset(x: 1)
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(boxBg)
        .overlay(boxStroke)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(label: "stream title") {
                TextField("", text: $title, prompt: Text("late night wwav").foregroundStyle(theme.muted))
                    .font(.wwav(23, weight: .light, italic: true))
                    .foregroundStyle(theme.ink)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().fill(theme.muted.opacity(0.3)).frame(height: 1), alignment: .bottom)
            }
            field(label: "notes") {
                TextEditor(text: $notes)
                    .scrollContentBackground(.hidden)
                    .font(.wwav(15, weight: .light))
                    .foregroundStyle(theme.ink)
                    .frame(minHeight: 76, maxHeight: 120)
                    .padding(12)
                    .background(boxBg)
                    .overlay(boxStroke)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                if mySession?.isLive == true {
                    // Reopen the DJ Console if the host dismissed it.
                    showingDJConsole = true
                } else {
                    goLiveOrSave()
                }
            } label: {
                Text(mySession?.isLive == true ? "open console" : "go live")
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
            .disabled(queueTrackIds.isEmpty)
            .opacity(queueTrackIds.isEmpty ? 0.5 : 1)

            if let mySession {
                HStack(spacing: 10) {
                    Button {
                        library.advanceRadio(id: mySession.id)
                    } label: {
                        controlPill("next")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive || mySession.queueTrackIds.count < 2)
                    .opacity(mySession.isLive && mySession.queueTrackIds.count > 1 ? 1 : 0.45)

                    Button {
                        broadcaster.endLive()
                        library.stopRadio(id: mySession.id)
                        hydrateFromSession()
                    } label: {
                        controlPill("end live")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mySession.isLive)
                    .opacity(mySession.isLive ? 1 : 0.45)
                }
            }

            if let savedAt, Date().timeIntervalSince(savedAt) < 5 {
                Text("saved")
                    .font(.wwav(11, weight: .light, italic: true))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.top, 4)
    }

    private func field<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).wwavLabel(size: 10, tracking: 2)
            content()
        }
    }

    private func controlPill(_ text: String) -> some View {
        Text(text)
            .font(.wwav(12, weight: .medium, italic: true))
            .tracking(1.4)
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(theme.sand.opacity(0.66)))
            .overlay(Capsule().stroke(theme.muted.opacity(0.20), lineWidth: 1))
    }

    private var boxBg: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(theme.sand.opacity(0.64))
    }

    private var boxStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(theme.muted.opacity(0.22), lineWidth: 1)
    }

    private func goLiveOrSave() {
        if let mySession {
            library.updateRadioSession(
                id: mySession.id,
                title: title,
                notes: notes,
                queueTrackIds: queueTrackIds
            )
            if !mySession.isLive {
                sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
            }
        } else {
            sessionId = library.startRadio(title: title, notes: notes, queueTrackIds: queueTrackIds)
        }
        savedAt = Date()
        hydrateFromSession()
        // Start mic capture and open the DJ Console.
        if let sid = sessionId {
            broadcaster.goLive(sessionId: sid)
            showingDJConsole = true
        }
    }

    private func hydrateFromSession() {
        guard let session = mySession else {
            if title.isEmpty { title = "\(library.profile.name)'s radio" }
            return
        }
        sessionId = session.id
        title = session.title
        notes = session.notes
        queueTrackIds = session.queueTrackIds
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}

private struct RadioPulseMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [theme.accent, theme.clayDeep],
                            center: UnitPoint(x: 0.35, y: 0.25),
                            startRadius: 1,
                            endRadius: w * 0.56
                        )
                    )
                Circle()
                    .stroke(theme.glow.opacity(0.7), lineWidth: 1.2)
                    .frame(width: w * 0.34, height: w * 0.34)
                ForEach([0.52, 0.72], id: \.self) { scale in
                    Circle()
                        .trim(from: 0.12, to: 0.88)
                        .stroke(theme.glow.opacity(0.76), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .frame(width: w * scale, height: w * scale)
                        .rotationEffect(.degrees(-90))
                }
                Capsule()
                    .fill(theme.glow)
                    .frame(width: w * 0.09, height: w * 0.34)
                    .offset(y: w * 0.16)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

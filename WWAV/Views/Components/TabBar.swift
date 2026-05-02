import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, play, plus, profile
    var id: String { rawValue }
}

struct TabBar: View {
    @Binding var active: AppTab
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        active = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if active == tab {
                                RadialGradient(
                                    colors: [theme.glow, theme.accent.opacity(0.32), .clear],
                                    center: .center, startRadius: 0, endRadius: 36
                                )
                                .frame(width: 72, height: 52)
                                .clipShape(Capsule())
                            }
                            TabIcon(tab: tab, active: active == tab)
                        }
                        .frame(width: 72, height: 52)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .contentShape(Rectangle())     // entire column is the tap target
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 30)
        .background(
            LinearGradient(colors: [theme.sand, theme.sandDeep],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

private struct TabIcon: View {
    let tab: AppTab
    let active: Bool
    @Environment(\.theme) private var theme
    var body: some View {
        let color = active ? theme.ink : theme.muted
        Group {
            switch tab {
            case .home:
                HomeIcon(stroke: color)
            case .play:
                PlayIcon(stroke: color, fill: color)
            case .plus:
                PlusIcon(stroke: color)
            case .profile:
                ProfileIcon(stroke: color)
            }
        }
        .frame(width: 38, height: 38)
    }
}

private struct HomeIcon: View {
    let stroke: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Path { p in
                let s = w / 24
                p.move(to: CGPoint(x: 3*s, y: 11*s))
                p.addLine(to: CGPoint(x: 12*s, y: 4*s))
                p.addLine(to: CGPoint(x: 21*s, y: 11*s))
                p.addLine(to: CGPoint(x: 21*s, y: 20*s))
                p.addLine(to: CGPoint(x: 15*s, y: 20*s))
                p.addLine(to: CGPoint(x: 15*s, y: 13*s))
                p.addLine(to: CGPoint(x: 9*s, y: 13*s))
                p.addLine(to: CGPoint(x: 9*s, y: 20*s))
                p.addLine(to: CGPoint(x: 3*s, y: 20*s))
                p.closeSubpath()
            }
            .stroke(stroke, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

private struct PlayIcon: View {
    let stroke: Color
    let fill: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle().stroke(stroke, lineWidth: 1.5).padding(1.5)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.42, y: w * 0.32))
                    p.addLine(to: CGPoint(x: w * 0.42, y: w * 0.68))
                    p.addLine(to: CGPoint(x: w * 0.68, y: w * 0.50))
                    p.closeSubpath()
                }.fill(fill)
            }
        }
    }
}

private struct PlusIcon: View {
    let stroke: Color
    var body: some View {
        ZStack {
            Capsule().fill(stroke).frame(width: 2, height: 18)
            Capsule().fill(stroke).frame(width: 18, height: 2)
        }
    }
}

private struct ProfileIcon: View {
    let stroke: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Circle()
                    .stroke(stroke, lineWidth: 1.5)
                    .frame(width: w * 0.32, height: w * 0.32)
                    .position(x: w * 0.5, y: w * 0.38)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.2, y: w * 0.85))
                    p.addQuadCurve(to: CGPoint(x: w * 0.8, y: w * 0.85),
                                   control: CGPoint(x: w * 0.5, y: w * 0.55))
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }
}

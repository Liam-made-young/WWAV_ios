import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, play, plus, profile
    var id: String { rawValue }
}

struct TabBar: View {
    @Binding var active: AppTab
    var onHomeTap: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    if tab == .home { onHomeTap() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        active = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if active == tab {
                                RadialGradient(
                                    colors: [
                                        theme.glow.opacity(0.82),
                                        theme.accent.opacity(0.18),
                                        theme.sand.opacity(0.04),
                                        .clear
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 44
                                )
                                .frame(width: 78, height: 48)
                                .clipShape(Capsule())
                            }
                            TabIcon(tab: tab, active: active == tab)
                        }
                        .frame(width: 72, height: 46)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .contentShape(Rectangle())     // entire column is the tap target
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
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
        let lineWidth: CGFloat = active ? 2.0 : 1.7
        Group {
            switch tab {
            case .home:
                HomeIcon(stroke: color, lineWidth: lineWidth)
            case .play:
                PlayIcon(stroke: color, fill: color, lineWidth: lineWidth)
            case .plus:
                PlusIcon(stroke: color, lineWidth: lineWidth)
            case .profile:
                ProfileIcon(stroke: color, lineWidth: lineWidth)
            }
        }
        .frame(width: 38, height: 38)
    }
}

private struct HomeIcon: View {
    let stroke: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let s = w / 24
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 4*s, y: 12.2*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 12*s, y: 5.2*s),
                        control: CGPoint(x: 7.2*s, y: 8*s)
                    )
                    p.addQuadCurve(
                        to: CGPoint(x: 20*s, y: 12.2*s),
                        control: CGPoint(x: 16.8*s, y: 8*s)
                    )
                    p.addLine(to: CGPoint(x: 20*s, y: 18.6*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 18.2*s, y: 20.4*s),
                        control: CGPoint(x: 20*s, y: 20.1*s)
                    )
                    p.addLine(to: CGPoint(x: 15.2*s, y: 20.4*s))
                    p.addLine(to: CGPoint(x: 15.2*s, y: 15*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 13.8*s, y: 13.6*s),
                        control: CGPoint(x: 15.2*s, y: 14.1*s)
                    )
                    p.addLine(to: CGPoint(x: 10.2*s, y: 13.6*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 8.8*s, y: 15*s),
                        control: CGPoint(x: 8.8*s, y: 14.1*s)
                    )
                    p.addLine(to: CGPoint(x: 8.8*s, y: 20.4*s))
                    p.addLine(to: CGPoint(x: 5.8*s, y: 20.4*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 4*s, y: 18.6*s),
                        control: CGPoint(x: 4*s, y: 20.1*s)
                    )
                    p.closeSubpath()
                }
                .stroke(
                    stroke,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

private struct PlayIcon: View {
    let stroke: Color
    let fill: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let s = w / 24
            ZStack {
                Circle()
                    .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .padding(2)
                Path { p in
                    p.move(to: CGPoint(x: 10.1*s, y: 8.2*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 11.7*s, y: 8.5*s),
                        control: CGPoint(x: 10.8*s, y: 7.8*s)
                    )
                    p.addLine(to: CGPoint(x: 17.2*s, y: 11.8*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 17.2*s, y: 12.9*s),
                        control: CGPoint(x: 18.1*s, y: 12.35*s)
                    )
                    p.addLine(to: CGPoint(x: 11.7*s, y: 16.2*s))
                    p.addQuadCurve(
                        to: CGPoint(x: 10.1*s, y: 15.8*s),
                        control: CGPoint(x: 10.8*s, y: 16.7*s)
                    )
                    p.closeSubpath()
                }
                .fill(fill)
            }
        }
    }
}

private struct PlusIcon: View {
    let stroke: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Capsule().fill(stroke).frame(width: lineWidth, height: 20)
            Capsule().fill(stroke).frame(width: 20, height: lineWidth)
        }
    }
}

private struct ProfileIcon: View {
    let stroke: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let s = w / 24
            ZStack {
                Path { p in
                    p.addEllipse(in: CGRect(x: 9*s, y: 5.2*s, width: 6*s, height: 6*s))
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                Path { p in
                    p.move(to: CGPoint(x: 5.3*s, y: 20.2*s))
                    p.addCurve(
                        to: CGPoint(x: 18.7*s, y: 20.2*s),
                        control1: CGPoint(x: 7.1*s, y: 15.4*s),
                        control2: CGPoint(x: 16.9*s, y: 15.4*s)
                    )
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

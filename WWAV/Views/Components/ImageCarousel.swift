import SwiftUI

/// Horizontal-paging image carousel for the feed. It uses each loaded
/// image's natural aspect ratio, clamped to a sane feed range, so portraits
/// do not take over the screen and panoramas do not collapse into slivers.
///
/// Sizing trick: a flexible view like `TabView` with `.page` style can
/// ignore simple aspect-ratio modifiers and try to claim its content's
/// natural width. Wrapping a `Color.clear` in the chosen aspect ratio and
/// overlaying the pager forces a real frame; the outer clips keep every
/// pixel inside the feed column.
struct ImageCarousel: View {
    let urls: [URL]
    var cornerRadius: CGFloat = 16
    @Environment(\.theme) private var theme
    @State private var index: Int = 0
    @State private var aspectRatios: [Int: CGFloat] = [:]

    private var activeAspectRatio: CGFloat {
        Self.feedAspectRatio(from: aspectRatios[index])
    }

    var body: some View {
        Color.clear
            .aspectRatio(activeAspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let width = geo.size.width
                    let height = geo.size.height
                    ZStack(alignment: .bottom) {
                        TabView(selection: $index) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                                page(for: url, index: i, width: width, height: height)
                                    .tag(i)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(width: width, height: height)
                        .clipped()

                        if urls.count > 1 {
                            HStack(spacing: 6) {
                                ForEach(0..<urls.count, id: \.self) { i in
                                    Circle()
                                        .fill(i == index ? theme.glow : theme.glow.opacity(0.4))
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.35)))
                            .padding(.bottom, 12)
                        }

                        if urls.count > 1 {
                            HStack {
                                Spacer()
                                Text("\(index + 1)/\(urls.count)")
                                    .font(.wwav(10, weight: .light))
                                    .foregroundStyle(theme.glow)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.black.opacity(0.35)))
                                    .padding(10)
                            }
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .frame(width: width, height: height)
                }
            }
            .frame(maxWidth: .infinity)        // never exceed parent column
            .clipped()                           // last-resort clip on the outside
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(theme.muted.opacity(0.20), lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.18), value: activeAspectRatio)
    }

    private func page(for url: URL, index: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            CachedAsyncImage(url: url, contentMode: .fit, onImageLoad: { image in
                let rawRatio = image.size.height > 0 ? image.size.width / image.size.height : 1
                aspectRatios[index] = rawRatio
            }) {
                Color.clear
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private static func feedAspectRatio(from raw: CGFloat?) -> CGFloat {
        let fallback: CGFloat = 1
        let ratio = raw ?? fallback
        guard ratio.isFinite, ratio > 0 else { return fallback }
        // Width / height. 4:5 is tall enough for portraits without making a
        // single feed item dominate; 16:9 keeps wide images legible.
        return min(max(ratio, 4.0 / 5.0), 16.0 / 9.0)
    }
}

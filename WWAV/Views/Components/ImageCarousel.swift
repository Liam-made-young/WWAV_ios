import SwiftUI

/// Square horizontal-paging image carousel for the feed. Shows up to 10
/// images, snaps page-by-page, and ALWAYS fits inside a 1:1 frame so wide
/// or tall source photos can't break the feed layout — the carousel itself
/// never grows beyond the column's width.
///
/// Sizing trick: a flexible view like `TabView` with `.page` style ignores
/// `.aspectRatio` modifiers and tries to claim its content's natural
/// width, which is what was making wide photos blow out of the column.
/// Wrapping a `Color.clear` in `.aspectRatio(1, .fit)` and overlaying the
/// pager forces a real 1:1 frame, then `.clipped()` and `.clipShape` on
/// the outside keep every pixel inside that frame.
struct ImageCarousel: View {
    let urls: [URL]
    var cornerRadius: CGFloat = 16
    @Environment(\.theme) private var theme
    @State private var index: Int = 0

    var body: some View {
        // Color.clear (a flexible view with no intrinsic size) wrapped in
        // `.aspectRatio(.fit)` is the cheapest way to claim a square box
        // within the parent's offered width — TabView/ScrollView would
        // otherwise expand to their content's natural size.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let side = min(geo.size.width, geo.size.height)
                    ZStack(alignment: .bottom) {
                        TabView(selection: $index) {
                            ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                                page(for: url, side: side).tag(i)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(width: side, height: side)
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
                    .frame(width: side, height: side)
                }
            }
            .frame(maxWidth: .infinity)        // never exceed parent column
            .clipped()                           // last-resort clip on the outside
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(theme.muted.opacity(0.20), lineWidth: 1)
            )
    }

    private func page(for url: URL, side: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [theme.clay.opacity(0.25), theme.clayDeep.opacity(0.15)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            CachedAsyncImage(url: url, contentMode: .fill) {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .clipped()
    }
}

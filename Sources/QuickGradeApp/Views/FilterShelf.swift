import AppKit
import QuickGradeCore
import SwiftUI

struct FilterShelf: View {
    var session: GradeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(PhotoFilter.allCases) { filter in
                        filterCell(filter)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            if session.settings.filter != .original {
                ValueSlider(
                    name: "Strength",
                    symbol: "camera.filters",
                    range: 0...100,
                    baseline: 0,
                    bipolar: false,
                    display: .unsignedHundred,
                    value: session.settings.filterStrength,
                    onBegin: { session.beginFilterStrengthEdit() },
                    onChange: { session.setFilterStrength($0) },
                    onEnd: { session.endEdit() }
                )
            }
        }
    }

    private func filterCell(_ filter: PhotoFilter) -> some View {
        let selected = session.settings.filter == filter
        return Button {
            session.selectFilter(filter)
        } label: {
            VStack(spacing: 6) {
                thumbnail(filter, selected: selected)
                Text(filter.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 72, height: 26, alignment: .top)
            }
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(_ filter: PhotoFilter, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ZStack {
            shape.fill(Color.white.opacity(0.08))
            if let image = session.filterThumbnails[filter] ?? (filter == .original ? session.originalImage : nil) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 72, height: 88)
        .clipShape(shape)
        .overlay(
            shape.stroke(selected ? Color.white : Color.white.opacity(0.16), lineWidth: selected ? 2 : 1)
        )
    }
}

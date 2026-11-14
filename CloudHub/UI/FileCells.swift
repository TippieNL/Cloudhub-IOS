import CloudHubCore
import SwiftUI

/// A file's picture: the server's thumbnail for photos and videos it has a
/// frame for, a frame decoded here for videos it has none for, and a tinted
/// glyph for everything else. Holds its place while loading and fades in.
struct Thumbnail: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.displayScale) private var scale
    let entry: FileEntry
    var side: CGFloat = 120

    @State private var image: UIImage?
    @State private var failed = false

    private var hasPicture: Bool {
        (entry.kind == .image && entry.ext != "svg") || entry.kind == .video
    }

    var body: some View {
        ZStack {
            if entry.isDirectory {
                LinearGradient(colors: [Brand.primary.opacity(0.16), Brand.accent.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "folder.fill")
                    .font(.system(size: side * 0.3))
                    .foregroundStyle(Brand.primary)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Brand.surfaceVariant
                if !hasPicture || failed {
                    Image(systemName: entry.symbol)
                        .font(.system(size: side * 0.26))
                        .foregroundStyle(.secondary)
                }
            }
            if entry.kind == .video && image != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: min(32, side * 0.28)))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: "\(entry.path)|\(entry.modified)") { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        guard hasPicture, image == nil else { return }
        let pixels = side * scale
        let url = app.api.thumbnailURL(entry)
        if let hit = app.images.memoryImage(for: url, maxPixels: pixels) {
            image = hit
            return
        }
        do {
            if entry.kind == .video && !entry.hasThumbnail {
                image = try await app.images.videoFrame(for: entry, maxPixels: pixels, trust: app.mediaTrust)
            } else {
                image = try await app.images.image(for: url, maxPixels: pixels)
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// One card of the grid.
struct FileTile: View {
    let entry: FileEntry
    let selected: Bool
    let favorite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                Thumbnail(entry: entry, side: geo.size.width)
                    .frame(width: geo.size.width, height: geo.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if favorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Brand.favorite)
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(5)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Brand.primary, lineWidth: 3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Brand.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(6)
                }
            }
            Text(entry.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(metaLine(entry))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One row of the list.
struct FileRow: View {
    let entry: FileEntry
    let selected: Bool
    let favorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(entry: entry, side: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(metaLine(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if favorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(Brand.favorite)
            }
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.primary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "Folder" or the size, then when it changed.
func metaLine(_ entry: FileEntry) -> String {
    let head = entry.isDirectory ? "Folder" : Format.bytes(entry.size)
    let date = shortDate(entry.modified)
    return date.isEmpty ? head : "\(head) · \(date)"
}

/// The listing's "2024-05-17 14:03:22" as the phone would write the date.
func shortDate(_ modified: String) -> String {
    let trimmed = modified.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "" }
    for parser in listingDateParsers {
        if let date = parser.date(from: trimmed) {
            return date.formatted(date: .abbreviated, time: Calendar.current.isDateInToday(date) ? .shortened : .omitted)
        }
    }
    return String(trimmed.prefix(10))
}

/// Made once: a DateFormatter is expensive, and every cell asks.
private let listingDateParsers: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss"].map {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = $0
    return parser
}

/// Placeholders shaped like the real cards, so content arriving changes colour, not position.
struct SkeletonGrid: View {
    let grid: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ScrollView {
            Group {
                if grid {
                    LazyVGrid(columns: FilesLayout.columns, spacing: 16) {
                        ForEach(0..<18, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 12).aspectRatio(1, contentMode: .fit)
                                RoundedRectangle(cornerRadius: 4).frame(height: 10)
                                RoundedRectangle(cornerRadius: 4).frame(width: 50, height: 8)
                            }
                        }
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 14) {
                        ForEach(0..<12, id: \.self) { _ in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 4).frame(height: 10)
                                    RoundedRectangle(cornerRadius: 4).frame(width: 90, height: 8)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .foregroundStyle(Brand.surfaceVariant)
            .opacity(pulse ? 0.55 : 1)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading this folder")
    }
}

enum FilesLayout {
    static let columns = [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14)]
}

import CloudHubCore
import SwiftUI
import UIKit

/// The web app's palette, so the three clients do not look like different products.
enum Brand {
    static let primary = dynamic(light: 0x1479C9, dark: 0x3296E6)
    /// A cooler second hue, used only for gradients beside the brand blue.
    static let accent = dynamic(light: 0x6F5BE8, dark: 0x8E7CF5)
    static let background = dynamic(light: 0xF7F7F8, dark: 0x151515)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1D1D1D)
    static let surfaceVariant = dynamic(light: 0xE9EAEE, dark: 0x2C2C2E)
    static let danger = dynamic(light: 0xB42318, dark: 0xE06C63)
    static let favorite = Color(red: 0.98, green: 0.75, blue: 0.14)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The launcher icon's own mark, drawn rather than imported: three bumps
/// over a slab, with the upload arrow knocked out of the cloud.
struct BrandMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                CloudShape()
                    .fill(LinearGradient(colors: [Brand.primary, Brand.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                ArrowShape()
                    .fill(Color.black)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.4)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55)) { appeared = true }
        }
        .accessibilityHidden(true)
    }
}

/// The unit box from tools/make-icons.php, in hundredths of the side.
private struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        var p = Path()
        p.addEllipse(in: CGRect(x: 13 * s, y: 33 * s, width: 34 * s, height: 34 * s))
        p.addEllipse(in: CGRect(x: 29 * s, y: 17 * s, width: 46 * s, height: 46 * s))
        p.addEllipse(in: CGRect(x: 59 * s, y: 37 * s, width: 30 * s, height: 30 * s))
        p.addRect(CGRect(x: 30 * s, y: 50 * s, width: 44 * s, height: 17 * s))
        return p
    }
}

private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        var p = Path()
        p.move(to: CGPoint(x: 52 * s, y: 26 * s))
        p.addLine(to: CGPoint(x: 67 * s, y: 46 * s))
        p.addLine(to: CGPoint(x: 37 * s, y: 46 * s))
        p.closeSubpath()
        p.addRect(CGRect(x: 46 * s, y: 44 * s, width: 12 * s, height: 28 * s))
        return p
    }
}

/* ---- toasts ---------------------------------------------------------------- */

private struct ToastOverlay: ViewModifier {
    @EnvironmentObject private var app: AppEnvironment

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastCard(toast: toast) { app.toast = nil }
                    .id(toast.id)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: toast.action == nil ? 3_000_000_000 : 6_000_000_000)
                        if app.toast?.id == toast.id { app.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.toast)
    }
}

private struct ToastCard: View {
    let toast: Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let label = toast.actionLabel, let action = toast.action {
                Button(label) {
                    action()
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(UIColor(hex: 0x7FC0F5)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(white: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}

/* ---- small shared pieces --------------------------------------------------- */

/// A centred message with an optional action: empty, failed, nothing matched.
struct MessageView: View {
    let systemImage: String
    let title: String
    var detail: String?
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if let actionLabel, let action {
                Button(actionLabel, action: action).buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension FileEntry {
    /// An SF Symbol for the kind of file.
    var symbol: String {
        switch kind {
        case .folder: return "folder.fill"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }

    var kindDescription: String {
        switch kind {
        case .folder: return "Folder"
        case .image: return ext == "gif" ? "GIF image" : "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF document"
        case .text: return "Text"
        case .other: return ext.isEmpty ? "File" : ext.uppercased()
        }
    }
}

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/*
 * Stand-ins for SwiftUI that arrived after iOS 15, so one code base runs on
 * every iPhone that can install iOS 15 (6s and later).
 */

extension View {
    /// Half-height sheets where the system has them (iOS 16); full height before.
    @ViewBuilder func mediumDetents() -> some View {
        if #available(iOS 16, *) {
            presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    @ViewBuilder func dismissKeyboardOnScroll() -> some View {
        if #available(iOS 16, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    /// The home indicator, out of the way in the immersive viewer.
    @ViewBuilder func systemOverlaysHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }
}

/// A label and its value on one row (LabeledContent is iOS 16).
struct LabeledRow<Label: View, Value: View>: View {
    let label: Label
    let value: Value

    init(@ViewBuilder value: () -> Value, @ViewBuilder label: () -> Label) {
        self.value = value()
        self.label = label()
    }

    var body: some View {
        HStack {
            label
            Spacer(minLength: 12)
            value.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

extension LabeledRow where Label == Text, Value == Text {
    init(_ title: String, value: String) {
        self.label = Text(title)
        self.value = Text(value)
    }
}

/// One line of text asked for: a folder name, a new name, a language code.
/// A sheet rather than an alert, because an alert with a text field is iOS 16.
struct TextPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    var message: String?
    var confirm = "OK"
    @State var text: String
    let onConfirm: (String) -> Void
    @FocusState private var focused: Bool

    init(title: String, placeholder: String, initial: String = "", message: String? = nil, confirm: String = "OK",
         onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.message = message
        self.confirm = confirm
        _text = State(initialValue: initial)
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(done)
                } footer: {
                    if let message { Text(message) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm, action: done)
                }
            }
        }
        .navigationViewStyle(.stack)
        .mediumDetents()
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
    }

    private func done() {
        onConfirm(text.trimmingCharacters(in: .whitespaces))
        dismiss()
    }
}

/// What a text prompt is for, so one sheet modifier serves them all.
struct PromptRequest: Identifiable {
    let id = UUID()
    let title: String
    let placeholder: String
    var initial = ""
    var message: String?
    var confirm = "OK"
    let onConfirm: (String) -> Void
}

/// The system photo picker (PHPicker, iOS 14): photos and videos, several at
/// once, no permission needed. Hands back copies of the original files.
struct PhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 50
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { return onPicked([]) }
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [URL] = []
            for result in results {
                let provider = result.itemProvider
                // A video first: a Live Photo's provider offers both.
                let type = [UTType.movie, UTType.image, UTType.item]
                    .first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
                guard let type else { continue }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { file, _ in
                    defer { group.leave() }
                    // Only readable inside this callback: copied out at once,
                    // into a folder of its own so the original name survives.
                    guard let file, let copy = try? Self.copy(file, suggested: provider.suggestedName) else { return }
                    lock.lock()
                    urls.append(copy)
                    lock.unlock()
                }
            }
            group.notify(queue: .main) { self.onPicked(urls) }
        }

        static func copy(_ source: URL, suggested: String?) throws -> URL {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var name = source.lastPathComponent
            if let suggested, !suggested.isEmpty {
                let ext = source.pathExtension
                name = ext.isEmpty || suggested.lowercased().hasSuffix("." + ext.lowercased()) ? suggested : "\(suggested).\(ext)"
            }
            let target = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }
}

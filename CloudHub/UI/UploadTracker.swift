import CloudHubCore
import SwiftUI

/// The bar at the bottom of the file list while anything is in flight, just
/// finished, or refused and not yet acknowledged.
struct UploadTrackerBar: View {
    @EnvironmentObject private var app: AppEnvironment
    let onTap: () -> Void

    private var center: UploadCenter { app.uploads }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").foregroundStyle(.secondary)
                }
                if center.summary.active {
                    ProgressView(value: center.summary.fraction).tint(Brand.primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeOut(duration: 0.3), value: center.summary.fraction)
    }

    private var icon: String {
        if center.summary.active { return "arrow.up.doc" }
        if center.justFinished { return "checkmark.circle.fill" }
        return "exclamationmark.circle"
    }

    private var tint: Color { center.summary.active || center.justFinished ? Brand.primary : Brand.danger }

    private var headline: String {
        if center.summary.active { return "Uploading — \(Int(center.summary.fraction * 100))%" }
        if center.justFinished { return "All uploads finished" }
        return center.failures.count == 1 ? "1 upload was refused" : "\(center.failures.count) uploads were refused"
    }

    private var detail: String? {
        let s = center.summary
        if s.active {
            var text = s.currentName.map { "\($0) · " } ?? ""
            text += "\(s.filesLeft) file\(Format.plural(s.filesLeft)) left · \(Format.bytes(s.doneBytes)) of \(Format.bytes(s.totalBytes))"
            return text
        }
        if center.justFinished { return nil }
        return "Tap to see why"
    }
}

/// Every file in the batch: the one moving, the ones waiting, and the refusals.
struct UploadsSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private var center: UploadCenter { app.uploads }

    var body: some View {
        NavigationView {
            List {
                if center.summary.active {
                    Section {
                        Text("\(Format.bytes(center.summary.doneBytes)) of \(Format.bytes(center.summary.totalBytes)) sent")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !center.queued.isEmpty {
                    Section("Queue") {
                        ForEach(center.queued) { item in
                            let moving = item.id == center.currentId
                            HStack(spacing: 12) {
                                Image(systemName: moving ? "arrow.up.doc" : "clock")
                                    .foregroundStyle(moving ? Brand.primary : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).lineLimit(1)
                                    Text(moving ? "\(Format.bytes(center.currentSent)) of \(Format.bytes(item.size))"
                                                : "Waiting · \(Format.bytes(item.size)) · to \(item.targetPath)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    // Only the file actually moving gets a bar; a row of
                                    // empty bars reads as stalled rather than queued.
                                    if moving {
                                        ProgressView(value: item.size <= 0 ? 0 : min(1, Double(center.currentSent) / Double(item.size)))
                                    }
                                }
                            }
                        }
                    }
                }
                if !center.failures.isEmpty {
                    Section {
                        ForEach(center.failures, id: \.self) { failure in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.name).lineLimit(1)
                                    // The server's own words, written for a person.
                                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.danger)
                            }
                        }
                        Button("Dismiss") { center.clearFailures() }
                    } header: {
                        Text("Refused").foregroundStyle(Brand.danger)
                    }
                }
                if center.queued.isEmpty && center.failures.isEmpty {
                    Text("Nothing is waiting to upload.").foregroundStyle(.secondary)
                }
                Section {
                    Text("Uploads carry on for a while after you leave the app, and iOS resumes the rest in the background when it can. Opening CloudHub always picks the queue up where it stopped.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Uploads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .mediumDetents()
    }
}

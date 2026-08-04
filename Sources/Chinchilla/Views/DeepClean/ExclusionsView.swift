import SwiftUI
import CleanCore

/// "Never touch this" — the user's own protected folders. Lives next to Deep
/// Clean because that's where deletions are reviewed; the list applies
/// everywhere, including the weekly clean and the command line.
struct ExclusionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = ExclusionsModel()
    @State private var selection: UserExclusions.Entry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Folders Chinchilla will never touch")
                    .font(.title3.bold())
                Text("Anything inside these folders is off limits — for cleaning, for the weekly auto-clean and for the command line.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Nothing is protected yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: (entry.path as NSString).lastPathComponent)
                                Text(verbatim: entry.path)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                model.remove(entry)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop protecting this folder")
                        }
                        .tag(entry.id)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("The list is a plain text file you can edit yourself: \(model.fileURL.path)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Button {
                    model.addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                Button("Show File") { model.revealFile() }
                    .disabled(model.entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onAppear { model.refresh() }
    }
}

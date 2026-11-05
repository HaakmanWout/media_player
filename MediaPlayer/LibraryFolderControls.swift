import SwiftUI
import UniformTypeIdentifiers

/// Toolbar button that opens the folder picker for choosing where a library reads its MP3s from.
struct LibraryFolderButton: View {
    @ObservedObject var library: LocalLibrary
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Image(systemName: "folder")
        }
        .accessibilityLabel("Library Folder")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await library.chooseFolder(url) }
            }
        }
        // Open on this page's folder. The iOS picker briefly shows the parent folder while it navigates
        // there; that's system behaviour the app can't suppress.
        .fileDialogDefaultDirectory(library.folderURL)
        .alert("Folder Error", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

struct EmptyLibraryView: View {
    @ObservedObject var library: LocalLibrary
    let title: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: library.kind == .music ? "music.note.list" : "mic")
        } description: {
            if library.kind == .music {
                Text("In the Files app, create a folder per playlist inside **\(library.folderDescription)** and add MP3 files to it, then pull to refresh.")
            } else {
                Text("Add MP3 files to **\(library.folderDescription)** in the Files app, then pull to refresh.")
            }
            if library.pendingDownloads > 0 {
                Text("\(library.pendingDownloads) file(s) are downloading from iCloud.")
            }
        } actions: {
            Button("Rescan") { Task { await library.reload() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @EnvironmentObject var adb: ADBClient
    @EnvironmentObject var nav: NavigationModel
    let path: String

    @State private var files: [DeviceFile] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var renameTarget: DeviceFile?
    @State private var renameNewName: String = ""
    @State private var newFolderShown = false
    @State private var newFolderName: String = ""
    @State private var deleteConfirm: DeviceFile?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let msg = errorMessage {
                ErrorBanner(message: msg) { errorMessage = nil }
            }
            if loading && files.isEmpty {
                ProgressView().padding()
            }
            List(files) { file in
                Button {
                    activate(file)
                } label: {
                    FileRow(file: file)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .contextMenu { contextMenu(for: file) }
                .onDrag { dragProvider(for: file) }
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if files.isEmpty && !loading {
                    Text("Empty folder")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .navigationTitle((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
        .navigationSubtitle(path)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    newFolderName = ""
                    newFolderShown = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Button(action: pushFromPicker) {
                    Label("Push File…", systemImage: "square.and.arrow.up")
                }

                Button(action: { Task { await refresh() } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task(id: refreshKey) { await refresh() }
        .alert("New folder", isPresented: $newFolderShown) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        } message: {
            Text("Create a new folder in \(path)")
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("New name", text: $renameNewName)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { Task { await commitRename() } }
        } message: {
            if let t = renameTarget { Text("Rename \(t.name) to:") }
        }
        .alert("Delete \(deleteConfirm?.name ?? "")?", isPresented: Binding(
            get: { deleteConfirm != nil },
            set: { if !$0 { deleteConfirm = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirm = nil }
            Button("Delete", role: .destructive) { Task { await commitDelete() } }
        } message: {
            Text("This permanently removes the item from the device.")
        }
    }

    private var refreshKey: String {
        "\(adb.selectedDeviceID ?? "none")::\(path)"
    }

    // MARK: - Actions

    private func activate(_ file: DeviceFile) {
        if file.isDirectory || file.isSymlink {
            nav.push(file.path)
        } else {
            open(file)
        }
    }

    private func open(_ file: DeviceFile) {
        if file.isDirectory || file.isSymlink {
            nav.push(file.path)
            return
        }
        Task {
            do {
                let url = try await adb.pullToTemp(file.path)
                NSWorkspace.shared.open(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for file: DeviceFile) -> some View {
        if file.isDirectory || file.isSymlink {
            Button("Open") { activate(file) }
        } else {
            Button("Open") { open(file) }
            Button("Save As…") { saveAs(file) }
        }
        Divider()
        Button("Rename…") {
            renameTarget = file
            renameNewName = file.name
        }
        Button("Delete", role: .destructive) { deleteConfirm = file }
    }

    private func saveAs(_ file: DeviceFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            Task {
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try await adb.pull(file.path, to: dest)
                } catch {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func pushFromPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            Task { await pushURLs(urls) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let url = await loadFileURL(from: p) {
                    urls.append(url)
                }
            }
            await pushURLs(urls)
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }

    private func pushURLs(_ urls: [URL]) async {
        for url in urls {
            do {
                try await adb.push(url, toRemoteDir: path)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
        await refresh()
    }

    private func commitRename() async {
        guard let t = renameTarget else { return }
        let trimmed = renameNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty, trimmed != t.name else { return }
        let parent = (t.path as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(trimmed)
        do {
            try await adb.rename(from: t.path, to: newPath)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitDelete() async {
        guard let t = deleteConfirm else { return }
        deleteConfirm = nil
        do {
            try await adb.delete(t.path)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder() async {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newPath = (path as NSString).appendingPathComponent(trimmed)
        do {
            try await adb.mkdir(newPath)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        guard adb.selectedDeviceID != nil else {
            files = []
            return
        }
        loading = true
        defer { loading = false }
        do {
            files = try await adb.list(path)
            errorMessage = nil
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Drag out (file promise)

    private func dragProvider(for file: DeviceFile) -> NSItemProvider {
        // The drop receiver appends the typeID's preferred extension to suggestedName.
        // To avoid "A.mp4.mp4", strip the extension from suggestedName when the type
        // already implies one. For unknown extensions, fall back to UTType.data which
        // has no preferred extension, and keep the full filename.
        let provider = NSItemProvider()
        let suggestedName: String
        let typeID: String
        if file.isDirectory {
            suggestedName = file.name
            typeID = UTType.folder.identifier
        } else {
            let ext = (file.name as NSString).pathExtension
            if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
                suggestedName = (file.name as NSString).deletingPathExtension
                typeID = ut.identifier
            } else {
                suggestedName = file.name
                typeID = UTType.data.identifier
            }
        }
        provider.suggestedName = suggestedName

        provider.registerFileRepresentation(
            forTypeIdentifier: typeID,
            fileOptions: [],
            visibility: .all
        ) { completionHandler in
            Task {
                do {
                    let url = try await adb.pullToTemp(file.path)
                    completionHandler(url, false, nil)
                } catch {
                    completionHandler(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

struct FileRow: View {
    let file: DeviceFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(file.displaySize)
                    Text(file.modifiedString)
                    Text(file.permissions).font(.system(.caption2, design: .monospaced))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if file.isDirectory || file.isSymlink {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if file.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        if file.isDirectory { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "wav", "m4a", "ogg", "flac": return "music.note"
        case "pdf": return "doc.richtext"
        case "txt", "md", "log": return "doc.text"
        case "zip", "tar", "gz", "7z", "rar": return "doc.zipper"
        default: return "doc"
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }
}


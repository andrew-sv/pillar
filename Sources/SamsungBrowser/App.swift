import SwiftUI
import AppKit

@MainActor
final class NavigationModel: ObservableObject {
    @Published var path: [String] = []
    func push(_ p: String) { path.append(p) }
}

@main
struct SamsungBrowserApp: App {
    @StateObject private var adb = ADBClient()
    @StateObject private var nav = NavigationModel()

    var body: some Scene {
        WindowGroup("Samsung Browser") {
            ContentView()
                .environmentObject(adb)
                .environmentObject(nav)
                .frame(minWidth: 600, minHeight: 480)
                .task { await adb.refreshDevices() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Devices") {
                    Task { await adb.refreshDevices() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var adb: ADBClient
    @EnvironmentObject var nav: NavigationModel

    var body: some View {
        Group {
            if adb.adbPath == nil {
                SetupView()
            } else {
                NavigationStack(path: $nav.path) {
                    RootsView()
                        .navigationDestination(for: String.self) { p in
                            FileBrowserView(path: p)
                        }
                }
                .onChange(of: adb.selectedDeviceID) { _ in
                    nav.path.removeAll()
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            TransfersHUD()
                .padding(12)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DevicePicker()
            }
        }
    }
}

struct TransfersHUD: View {
    @EnvironmentObject var adb: ADBClient

    var body: some View {
        if adb.transfers.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(adb.transfers) { t in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Image(systemName: t.direction == .pull ? "arrow.down.circle" : "arrow.up.circle")
                            .foregroundStyle(.tint)
                        Text(t.direction == .pull ? "Pulling" : "Pushing")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(t.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 280, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 6)
        }
    }
}

struct StorageRoot: Identifiable, Hashable {
    let id: String   // path
    let label: String
    let path: String
    let symbol: String
}

struct RootsView: View {
    @EnvironmentObject var adb: ADBClient
    @EnvironmentObject var nav: NavigationModel

    private let roots: [StorageRoot] = [
        StorageRoot(id: "/sdcard", label: "Internal Storage", path: "/sdcard", symbol: "internaldrive"),
        StorageRoot(id: "/storage/extSdCard", label: "SD Card", path: "/storage/extSdCard", symbol: "sdcard"),
        StorageRoot(id: "/storage", label: "All Storage", path: "/storage", symbol: "externaldrive.connected.to.line.below"),
        StorageRoot(id: "/", label: "Filesystem Root", path: "/", symbol: "folder")
    ]

    var body: some View {
        List(roots) { root in
            Button {
                nav.push(root.path)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: root.symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading) {
                        Text(root.label).font(.body)
                        Text(root.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Locations")
        .overlay {
            if adb.selectedDeviceID == nil {
                Text("No device selected")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SetupView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("ADB not found").font(.title2).bold()
            Text("Install Android platform tools and relaunch:")
            Text("brew install --cask android-platform-tools")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
                .textSelection(.enabled)
        }
        .padding(40)
    }
}

struct DevicePicker: View {
    @EnvironmentObject var adb: ADBClient

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
            if adb.devices.isEmpty {
                Text("No devices").foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: Binding(
                    get: { adb.selectedDeviceID ?? "" },
                    set: { adb.selectedDeviceID = $0.isEmpty ? nil : $0 }
                )) {
                    ForEach(adb.devices) { d in
                        Text(d.displayName).tag(d.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 220)
            }
            Button {
                Task { await adb.refreshDevices() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh device list")
        }
    }
}

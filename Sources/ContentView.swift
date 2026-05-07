import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store = ConnectionStore.shared
    @State private var editing: Connection? = nil
    @State private var showingAdd = false
    @State private var proxyOn = false
    @State private var lastStatus: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { refreshProxyState() }
        .sheet(item: $editing) { conn in
            ConnectionEditView(connection: conn) { updated in
                store.update(updated)
                editing = nil
            } onCancel: { editing = nil }
        }
        .sheet(isPresented: $showingAdd) {
            ConnectionEditView(connection: Connection(name: "Neue Verbindung", type: .ollama, endpoint: BackendType.ollama.defaultEndpoint, model: "")) { added in
                store.add(added)
                showingAdd = false
            } onCancel: { showingAdd = false }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "terminal.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Launcher").font(.title2).fontWeight(.semibold)
                Text("Öffne Claude im Terminal — mit API oder lokalem LLM").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label("Hinzufügen", systemImage: "plus")
            }
        }
        .padding()
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(store.connections) { conn in
                    ConnectionRow(connection: conn,
                                  isDefault: conn.id == store.defaultId,
                                  onOpen: { openTerminal(connection: conn) },
                                  onEdit: { editing = conn },
                                  onSetDefault: { store.setDefault(id: conn.id) },
                                  onDelete: { store.remove(id: conn.id) })
                }
                if store.connections.isEmpty {
                    Text("Noch keine Verbindungen — klicke auf «Hinzufügen»").foregroundStyle(.secondary).padding()
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle().frame(width: 8, height: 8).foregroundStyle(proxyOn ? .green : .secondary)
            Text(proxyOn ? "Proxy läuft auf Port \(store.proxyPort)" : "Proxy gestoppt")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("Installieren") {
                Button("In Finder-Toolbar einfügen") {
                    lastStatus = installPickerInToolbar()
                }
                Button("Quick Actions (Rechtsklick)") {
                    lastStatus = QuickActionInstaller.installAll()
                }
                Divider()
                Button("Aus Finder-Toolbar entfernen") {
                    let r1 = FinderToolbarManager.uninstall()
                    ToolbarAppInstaller.uninstallAll()
                    lastStatus = r1
                }
                Button("Quick Actions entfernen") {
                    QuickActionInstaller.uninstallAll()
                    lastStatus = "Quick Actions entfernt"
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(proxyOn ? "Proxy stoppen" : "Proxy starten") {
                if proxyOn {
                    ProxyManager.shared.stop()
                } else {
                    ProxyManager.shared.ensureRunning()
                }
                refreshProxyState()
            }
            if !lastStatus.isEmpty {
                Text(lastStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
    }

    private func openTerminal(connection: Connection) {
        let path = FinderService.currentPath()
        TerminalLauncher.launch(path: path, connection: connection)
    }

    /// Generate the picker .app bundle and inject it into the Finder toolbar
    /// in one step. After this the user has a clickable button in every Finder
    /// window — no manual ⌘-drag required.
    private func installPickerInToolbar() -> String {
        // 1. Make sure ~/Applications/Claude Launcher/Claude ▾.app exists.
        let creation = ToolbarAppInstaller.installAll()
        if creation.hasPrefix("Fehler") { return creation }
        // 2. Add it to com.apple.finder's toolbar config and relaunch Finder.
        return FinderToolbarManager.install()
    }

    private func refreshProxyState() {
        Task.detached {
            let on = ProxyManager.shared.isReachable()
            await MainActor.run { self.proxyOn = on }
        }
    }
}

struct ConnectionRow: View {
    let connection: Connection
    let isDefault: Bool
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onSetDefault: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .foregroundStyle(connection.type.isLocal ? .orange : .blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name).fontWeight(.medium)
                    if isDefault {
                        Text("DEFAULT")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .foregroundStyle(.tint)
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Split button: main click opens, arrow opens menu
            HStack(spacing: 0) {
                Button(action: onOpen) {
                    Label("Öffnen", systemImage: "arrow.up.right.square")
                }
                .controlSize(.regular)

                Menu {
                    if !isDefault {
                        Button("Als Default markieren", action: onSetDefault)
                    }
                    Button("Bearbeiten…", action: onEdit)
                    Divider()
                    Button("Löschen", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "chevron.down")
                        .padding(.horizontal, 6)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch connection.type {
        case .anthropic: return "cloud.fill"
        case .ollama:    return "cube.fill"
        case .lmstudio:  return "memorychip.fill"
        }
    }

    private var subtitle: String {
        var parts: [String] = [connection.type.label]
        if !connection.model.isEmpty { parts.append(connection.model) }
        if connection.type.isLocal { parts.append(connection.endpoint) }
        return parts.joined(separator: " · ")
    }
}

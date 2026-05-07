import Foundation
import AppKit
import SwiftUI

/// Custom popup window with the connection list. Replaces the NSMenu-based
/// approach so we can position the popup right under the Finder-toolbar icon
/// and control its dismiss behaviour ourselves.
final class PickerController: NSObject, NSApplicationDelegate {

    private static var keepAlive: PickerController?

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = PickerController()
        keepAlive = controller
        app.delegate = controller
        app.run()
        exit(0)
    }

    private var window: PickerPanel?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.show()
        }
    }

    // MARK: - Show / Dismiss

    private func show() {
        let store = ConnectionStore.shared
        store.load()

        let view = PickerView(
            store: store,
            onPick: { [weak self] conn in self?.handlePick(conn) },
            onSettings: { [weak self] in self?.openSettings() }
        )

        let hosting = NSHostingController(rootView: view)
        // Force the SwiftUI view to compute its natural size.
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize

        let origin = positionedOrigin(for: size, anchoredTo: NSEvent.mouseLocation)

        let panel = PickerPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)
        window = panel

        // Dismiss when user clicks outside the popup or in another app.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
        // Esc inside the popup → dismiss.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    /// Place the popup near the click position, but clamped onto the visible
    /// screen so it never gets cut off at edges.
    private func positionedOrigin(for size: NSSize, anchoredTo mouse: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) ?? NSScreen.main!
        let f = screen.visibleFrame
        // Place the window so its top edge is just below the mouse and its
        // horizontal center aligns with the mouse.
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 6
        // Clamp horizontally.
        if x < f.minX + 6 { x = f.minX + 6 }
        if x + size.width > f.maxX - 6 { x = f.maxX - 6 - size.width }
        // If we'd run off the bottom, flip above the mouse.
        if y < f.minY + 6 {
            y = mouse.y + 6
            if y + size.height > f.maxY - 6 { y = f.maxY - 6 - size.height }
        }
        return NSPoint(x: x, y: y)
    }

    private func dismiss() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        window?.orderOut(nil)
        window = nil
        NSApp.terminate(nil)
    }

    // MARK: - Selection handlers

    private func handlePick(_ conn: Connection) {
        // Resolve the path BEFORE we close the popup — otherwise the front
        // Finder window we just stole focus from might already have changed.
        let path = FinderService.currentPath()
        // Tear down popup first so Finder regains focus, then launch.
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        window?.orderOut(nil)
        window = nil
        TerminalLauncher.launch(path: path, connection: conn)
        Thread.sleep(forTimeInterval: 0.3)
        NSApp.terminate(nil)
    }

    private func openSettings() {
        let bin = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let task = Process()
        task.launchPath = bin
        task.arguments = []
        try? task.run()
        dismiss()
    }
}

/// Borderless panel that accepts key status so SwiftUI hover/click events fire.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - SwiftUI View

private struct PickerView: View {
    @ObservedObject var store: ConnectionStore
    let onPick: (Connection) -> Void
    let onSettings: () -> Void
    @State private var hoverID: UUID? = nil

    private var others: [Connection] {
        store.connections.filter { $0.id != store.defaultId }
    }
    private var defaultConn: Connection? {
        store.connections.first { $0.id == store.defaultId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Default at the top.
            if let def = defaultConn {
                row(for: def, isDefault: true)
            }
            if !others.isEmpty {
                if defaultConn != nil { Divider().padding(.vertical, 4) }
                ForEach(others) { c in row(for: c, isDefault: false) }
            }
            if defaultConn == nil && others.isEmpty {
                Text("Keine Verbindungen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider().padding(.vertical, 4)
            Button(action: onSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").frame(width: 16)
                    Text("Settings öffnen…")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(hoverID == settingsHoverID ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)
            .onHover { inside in hoverID = inside ? settingsHoverID : nil }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private let settingsHoverID = UUID()

    private func row(for c: Connection, isDefault: Bool) -> some View {
        Button(action: { onPick(c) }) {
            HStack(spacing: 10) {
                Image(systemName: iconName(c))
                    .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).fontWeight(isDefault ? .medium : .regular)
                    if !subtitle(c).isEmpty {
                        Text(subtitle(c)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isDefault {
                    Text("DEFAULT")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18))
                        .foregroundStyle(.tint)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(hoverID == c.id ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { inside in hoverID = inside ? c.id : nil }
    }

    private func iconName(_ c: Connection) -> String {
        switch c.type {
        case .anthropic: return "cloud.fill"
        case .ollama:    return "cube.fill"
        case .lmstudio:  return "memorychip.fill"
        }
    }

    private func subtitle(_ c: Connection) -> String {
        switch c.type {
        case .anthropic: return "Anthropic API"
        case .ollama:    return c.model.isEmpty ? "Ollama" : "Ollama · \(c.model)"
        case .lmstudio:  return c.model.isEmpty ? "LM Studio" : "LM Studio · \(c.model)"
        }
    }
}

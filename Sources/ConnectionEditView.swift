import SwiftUI

struct ConnectionEditView: View {
    @State var connection: Connection
    let onSave: (Connection) -> Void
    let onCancel: () -> Void

    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var showApiKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Verbindung bearbeiten").font(.title3).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            Divider()
            Form {
                TextField("Name", text: $connection.name)
                Picker("Typ", selection: $connection.type) {
                    ForEach(BackendType.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .onChange(of: connection.type) { _, new in
                    connection.endpoint = new.defaultEndpoint
                    connection.model = ""
                    availableModels = []
                    if new.isLocal { Task { await refreshModels() } }
                }

                TextField("Endpoint", text: $connection.endpoint)
                    .disabled(connection.type == .anthropic)

                if connection.type == .anthropic {
                    HStack {
                        if showApiKey {
                            TextField("API Key (sk-ant-…)", text: Binding(
                                get: { connection.apiKey ?? "" },
                                set: { connection.apiKey = $0 }))
                        } else {
                            SecureField("API Key (sk-ant-…)", text: Binding(
                                get: { connection.apiKey ?? "" },
                                set: { connection.apiKey = $0 }))
                        }
                        Button { showApiKey.toggle() } label: {
                            Image(systemName: showApiKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    HStack {
                        if availableModels.isEmpty {
                            TextField("Modell-Name (z.B. qwen2.5-coder:32b)", text: $connection.model)
                        } else {
                            Picker("Modell", selection: $connection.model) {
                                Text("— wählen —").tag("")
                                ForEach(availableModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                        }
                        Button {
                            Task { await refreshModels() }
                        } label: {
                            if loadingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .help("Modelle vom Server abrufen")
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
            .frame(minHeight: 260)

            Divider()
            HStack {
                if connection.type.isLocal {
                    Text("Tipp: Tool-Use funktioniert mit kleinen lokalen Modellen oft schlecht.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abbrechen", action: onCancel)
                Button("Speichern") {
                    onSave(connection)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connection.name.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 380)
        .onAppear {
            if connection.type.isLocal { Task { await refreshModels() } }
        }
    }

    private func refreshModels() async {
        await MainActor.run { loadingModels = true }
        let models = await ModelDiscovery.models(for: connection.type, endpoint: connection.endpoint)
        await MainActor.run {
            self.availableModels = models
            self.loadingModels = false
        }
    }
}

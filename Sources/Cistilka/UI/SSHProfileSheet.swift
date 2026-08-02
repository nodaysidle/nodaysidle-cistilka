import SwiftUI
import UniformTypeIdentifiers

/// Form to create/edit an SSH profile, store secrets in Keychain, and test SFTP.
struct SSHProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, save updates this profile id (credentials optional if left blank).
    var existingProfile: SSHProfile? = nil

    @State private var displayName: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authMethod: SSHAuthMethod = .password
    @State private var password: String = ""
    @State private var privateKeyPEM: String = ""
    @State private var passphrase: String = ""
    @State private var remotePath: String = "/"
    @State private var remoteTrashPath: String = ""
    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var showKeyImporter = false
    @State private var didPrefill = false

    private var isEditing: Bool { existingProfile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Profile") {
                    TextField("Display name", text: $displayName)
                    TextField("Host", text: $host)
                    TextField("Port", text: $port)
                        .frame(maxWidth: 100)
                    TextField("Username", text: $username)
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        Text("Password").tag(SSHAuthMethod.password)
                        Text("Private key").tag(SSHAuthMethod.privateKey)
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .password {
                        SecureField(
                            isEditing ? "Password (leave blank to keep)" : "Password",
                            text: $password
                        )
                    } else {
                        TextEditor(text: $privateKeyPEM)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 100, maxHeight: 160)
                        if isEditing {
                            Text("Leave key blank to keep the stored key.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button("Import private key…") {
                            showKeyImporter = true
                        }
                        SecureField("Passphrase (optional)", text: $passphrase)
                    }
                }

                Section("Paths") {
                    TextField("Remote path", text: $remotePath)
                    TextField("Remote trash path (optional)", text: $remoteTrashPath)
                    Text(
                        "If trash path is empty, deleting requires typing DELETE (permanent remove)."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isBusy)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Test connection") {
                    Task { await testConnection() }
                }
                .disabled(isBusy || !canSave)

                Button(isEditing ? "Save & Rescan" : "Save & Scan") {
                    Task { await saveAndScan() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || !canSave)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 520)
        .navigationTitle(isEditing ? "Edit SSH" : "Add SSH")
        .onAppear { prefillIfNeeded() }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [.plainText, .data, UTType(filenameExtension: "pem")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importKey(from: url)
            }
        }
    }

    private var canSave: Bool {
        let baseOK = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(port) != nil
        if isEditing {
            // Secrets optional when editing (keep existing Keychain values).
            return baseOK
        }
        return baseOK
            && (authMethod == .password
                ? !password.isEmpty
                : !privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func prefillIfNeeded() {
        guard !didPrefill, let profile = existingProfile else { return }
        didPrefill = true
        displayName = profile.displayName
        host = profile.host
        port = String(profile.port)
        username = profile.username
        authMethod = profile.authMethod
        remotePath = profile.remotePath
        remoteTrashPath = profile.remoteTrashPath ?? ""
    }

    private func buildProfile() -> SSHProfile {
        let portValue = Int(port) ?? 22
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? "\(username)@\(host)" : name
        let trash = remoteTrashPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return SSHProfile(
            id: existingProfile?.id ?? UUID(),
            displayName: resolvedName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portValue,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            remotePath: remotePath,
            remoteTrashPath: trash.isEmpty ? nil : trash
        )
    }

    private func buildSecrets() async -> SSHSecrets {
        if isEditing, let id = existingProfile?.id {
            let existing = try? await model.sshCredentialStore.loadSecrets(profileId: id)
            switch authMethod {
            case .password:
                let pwd = password.isEmpty ? existing?.password : password
                return SSHSecrets(password: pwd, privateKeyPEM: nil, passphrase: nil)
            case .privateKey:
                let key = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? existing?.privateKeyPEM
                    : privateKeyPEM
                let pass = passphrase.isEmpty ? existing?.passphrase : passphrase
                return SSHSecrets(password: nil, privateKeyPEM: key, passphrase: pass)
            }
        }
        switch authMethod {
        case .password:
            return SSHSecrets(password: password, privateKeyPEM: nil, passphrase: nil)
        case .privateKey:
            return SSHSecrets(
                password: nil,
                privateKeyPEM: privateKeyPEM,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
        }
    }

    private func importKey(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            privateKeyPEM = text
            statusMessage = "Loaded key from \(url.lastPathComponent)."
        } else {
            statusMessage = "Could not read key file."
        }
    }

    @MainActor
    private func testConnection() async {
        isBusy = true
        statusMessage = "Connecting…"
        defer { isBusy = false }
        do {
            let secrets = await buildSecrets()
            try await model.testSSHConnection(profile: buildProfile(), secrets: secrets)
            statusMessage = "Connection OK. Host key trusted (TOFU)."
        } catch {
            statusMessage = "Test failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func saveAndScan() async {
        isBusy = true
        statusMessage = "Saving…"
        defer { isBusy = false }
        do {
            let secrets = await buildSecrets()
            guard secrets.password != nil || secrets.privateKeyPEM != nil else {
                statusMessage = "Missing credentials. Enter a password or private key."
                return
            }
            try await model.saveSSHProfileAndScan(profile: buildProfile(), secrets: secrets)
            dismiss()
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SSHProfileSheet()
        .environment(AppModel())
}

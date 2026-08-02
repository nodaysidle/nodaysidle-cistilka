import SwiftUI

struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Text("Optional accounts")
                    .font(.headline)
                Text(
                    "Cistilka is a local disk cleaner first. Google Drive, OneDrive, and SSH are optional and not required for normal use."
                )
                .foregroundStyle(.secondary)
            }

            Section("Google Drive (optional)") {
                if model.isGoogleOAuthConfigured {
                    Text("Configured. Connect requests Drive list + Trash access (offline refresh).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Not configured. Copy Config/OAuth.example.plist to Config/OAuth.plist and set GoogleClientID / GoogleRedirectURI. See README."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if model.googleAccounts.isEmpty {
                    Text("No Google accounts signed in.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.googleAccounts, id: \.self) { email in
                        HStack {
                            Label(email, systemImage: "person.crop.circle")
                            Spacer()
                            Button("Sign Out", role: .destructive) {
                                model.signOutGoogle(accountId: email)
                            }
                        }
                    }
                }

                Button("Connect Google Drive…") {
                    model.connectGoogle()
                }
                .disabled(!model.isGoogleOAuthConfigured)
            }

            Section("OneDrive (optional)") {
                if model.isMicrosoftOAuthConfigured {
                    Text("Configured. Connect requests Files.ReadWrite + User.Read with offline refresh (recycle-bin trash).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Not configured. Copy Config/OAuth.example.plist to Config/OAuth.plist and set MicrosoftClientID / MicrosoftRedirectURI. See README."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if model.microsoftAccounts.isEmpty {
                    Text("No Microsoft accounts signed in.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.microsoftAccounts, id: \.self) { email in
                        HStack {
                            Label(email, systemImage: "person.crop.circle")
                            Spacer()
                            Button("Sign Out", role: .destructive) {
                                model.signOutMicrosoft(accountId: email)
                            }
                        }
                    }
                }

                Button("Connect OneDrive…") {
                    model.connectOneDrive()
                }
                .disabled(!model.isMicrosoftOAuthConfigured)
            }

            Section("SSH (optional)") {
                Text(
                    "Profiles store host/user/path in Application Support; passwords and keys stay in Keychain. Host keys use TOFU (first connect trusts; changes are blocked)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if model.sshProfiles.isEmpty {
                    Text("No SSH profiles.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sshProfiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(profile.displayName, systemImage: "server.rack")
                                Text("\(profile.username)@\(profile.host):\(profile.port) · \(profile.remotePath)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Edit") {
                                model.editSSH(profile)
                            }
                            Button("Delete", role: .destructive) {
                                model.deleteSSHProfile(profile)
                            }
                        }
                    }
                }

                Button("Add SSH…") {
                    model.addSSH()
                }
            }

            Section("OAuth setup") {
                Text(
                    "Create Config/OAuth.plist from OAuth.example.plist (gitignored). Redirect URI schemes must match Info.plist CFBundleURLTypes: com.nodaysidle.cistilka and msauth.com.nodaysidle.cistilka."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Reload OAuth.plist") {
                    model.reloadOAuthConfig()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 320)
        .task {
            model.reloadOAuthConfig()
            await model.refreshGoogleAccounts()
            await model.refreshMicrosoftAccounts()
            await model.refreshSSHProfiles()
        }
    }
}

#Preview {
    AccountsSettingsView()
        .environment(AppModel())
}

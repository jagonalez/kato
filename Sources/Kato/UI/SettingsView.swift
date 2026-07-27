import SwiftUI

/// Settings pane inside the expanded panel (gear in the header). Currently
/// just Slack: paste the user token, or the refresh-token trio for
/// rotating workspaces. Writes to the app-support dir and restarts the
/// monitor — no env vars, no shell.
struct SettingsView: View {
    @ObservedObject var appState: AppState

    @State private var userToken = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var refreshToken = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Slack")
                .font(.headline)
            Text("Create the app from docs/slack-app-manifest.yaml, install it to your workspace, and paste the User OAuth Token (xoxp-…).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("User token (xoxp-…)", text: $userToken)
                .textFieldStyle(.roundedBorder)

            Text("Workspace rotates tokens (12 h expiry)? Also add:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
            SecureField("Refresh token (xoxe-…)", text: $refreshToken)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Save") {
                    appState.saveSlackSettings(userToken: userToken, clientID: clientID,
                                               clientSecret: clientSecret, refreshToken: refreshToken)
                    saved = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Clear") {
                    userToken = ""
                    clientID = ""
                    clientSecret = ""
                    refreshToken = ""
                    appState.saveSlackSettings(userToken: "", clientID: "",
                                               clientSecret: "", refreshToken: "")
                }
                .controlSize(.small)
                if saved, let status = appState.slackStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            let settings = appState.loadSlackSettings()
            userToken = settings.userToken
            clientID = settings.clientID
            clientSecret = settings.clientSecret
            refreshToken = settings.refreshToken
        }
    }
}

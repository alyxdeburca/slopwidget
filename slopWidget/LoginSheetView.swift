import SwiftUI

public struct LoginSheetView: View {
    @ObservedObject public var authManager = AuthManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: ServiceProviderType = .antigravity
    @State private var apiKeyInput: String = ""
    @State private var identifierInput: String = ""
    @State private var showingKey: Bool = false
    @State private var statusMessage: String?
    @State private var isSuccess: Bool = false
    @State private var isSigningIn: Bool = false
    @State private var isSigningInWithGoogle: Bool = false
    @State private var isSigningInOpenCode: Bool = false
    @State private var openCodeLoginTask: Task<Void, Never>?

    private let oauthClientFactory: @MainActor () -> ChatGPTOAuthClient
    private let googleOAuthClientFactory: @MainActor () -> AntigravityOAuthClient
    private let openCodeOAuthClientFactory: @MainActor () -> OpenCodeOAuthClient

    public init(
        oauthClientFactory: @escaping @MainActor () -> ChatGPTOAuthClient = {
            ChatGPTOAuthClientFactory.makeDefault()
        },
        googleOAuthClientFactory: @escaping @MainActor () -> AntigravityOAuthClient = {
            AntigravityOAuthClientFactory.makeDefault()
        },
        openCodeOAuthClientFactory: @escaping @MainActor () -> OpenCodeOAuthClient = {
            OpenCodeOAuthClientFactory.makeDefault()
        }
    ) {
        self.oauthClientFactory = oauthClientFactory
        self.googleOAuthClientFactory = googleOAuthClientFactory
        self.openCodeOAuthClientFactory = openCodeOAuthClientFactory
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Service selector tabs
                    Picker("Service", selection: $selectedTab) {
                        ForEach(ServiceProviderType.allCases) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTab) {
                        loadCurrentServiceValues()
                    }

                    // Active Service Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: selectedTab.icon)
                                .font(.title2)
                                .foregroundColor(selectedTab.brandColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedTab.displayName)
                                    .font(.headline)
                                Text(serviceDescription(for: selectedTab))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            let creds = authManager.credentials(for: selectedTab)
                            if creds.isLoggedIn {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            } else {
                                Label("Not Connected", systemImage: "xmark.circle")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        // Google OAuth (Antigravity only)
                        if selectedTab == .antigravity {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Google Account")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)

                                Button {
                                    performGoogleLogin()
                                } label: {
                                    HStack(spacing: 8) {
                                        if isSigningInWithGoogle {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "globe")
                                        }
                                        Text(isSigningInWithGoogle ? "Signing in…" : "Sign in with Google")
                                    }
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        Color(red: 0.26, green: 0.52, blue: 0.96),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                }
                                .disabled(isSigningInWithGoogle || authManager.antigravityAuthState.isBusy)

                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: googleStatusIcon)
                                        .font(.caption2)
                                        .foregroundColor(googleStatusColor)
                                    Text(authManager.antigravityAuthState.statusText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if authManager.antigravityAuthMethod == .google && authManager.antigravityCreds.isLoggedIn {
                                    Button {
                                        authManager.logout(type: .antigravity)
                                        apiKeyInput = ""
                                        identifierInput = ""
                                        statusMessage = "Signed out of Google."
                                        isSuccess = false
                                    } label: {
                                        Text("Sign out of Google")
                                            .font(.caption.bold())
                                            .foregroundColor(.red)
                                    }
                                }
                            }

                            Divider()

                            Text("Manual API key (fallback)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }

                        // ChatGPT OAuth (Codex only)
                        if selectedTab == .codex {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("ChatGPT Account")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)

                                Button {
                                    performChatGPTLogin()
                                } label: {
                                    HStack(spacing: 8) {
                                        if isSigningIn {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "person.crop.circle.badge.checkmark")
                                        }
                                        Text(isSigningIn ? "Signing in…" : "Sign in with ChatGPT")
                                    }
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(red: 0.06, green: 0.42, blue: 0.31), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .disabled(isSigningIn || authManager.chatGPTAuthState.isBusy)

                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: chatGPTStatusIcon)
                                        .font(.caption2)
                                        .foregroundColor(chatGPTStatusColor)
                                    Text(authManager.chatGPTAuthState.statusText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if authManager.codexAuthMethod == .chatGPT && authManager.codexCreds.isLoggedIn {
                                    Button {
                                        authManager.logout(type: .codex)
                                        apiKeyInput = ""
                                        identifierInput = ""
                                        statusMessage = "Signed out of ChatGPT."
                                        isSuccess = false
                                    } label: {
                                        Text("Sign out of ChatGPT")
                                            .font(.caption.bold())
                                            .foregroundColor(.red)
                                    }
                                }
                            }

                            Divider()

                            Text("Manual token (fallback)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }

                        // OpenCode device grant (OpenCode Go only)
                        if selectedTab == .opencodeGo {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("OpenCode Account")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)

                                Button {
                                    performOpenCodeLogin()
                                } label: {
                                    HStack(spacing: 8) {
                                        if isSigningInOpenCode {
                                            ProgressView()
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "person.badge.key.fill")
                                        }
                                        Text(isSigningInOpenCode ? "Signing in…" : "Sign in with OpenCode")
                                    }
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(red: 0.13, green: 0.42, blue: 0.78), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .disabled(isSigningInOpenCode || authManager.openCodeAuthState.isBusy)

                                if let code = authManager.openCodeAuthState.userCode {
                                    HStack(spacing: 10) {
                                        Text(code)
                                            .font(.system(.title3, design: .monospaced).bold())
                                        Spacer()
                                        if let url = authManager.openCodeAuthState.verificationURL {
                                            Link("Open page", destination: url)
                                                .font(.caption.bold())
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                }

                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: openCodeStatusIcon)
                                        .font(.caption2)
                                        .foregroundColor(openCodeStatusColor)
                                    Text(authManager.openCodeAuthState.statusText)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if authManager.openCodeAuthState.isBusy {
                                    Button("Cancel sign-in") {
                                        cancelOpenCodeLogin()
                                    }
                                    .font(.caption.bold())
                                    .foregroundColor(.orange)
                                }

                                if authManager.openCodeAuthMethod == .oauth && authManager.opencodeGoCreds.isLoggedIn {
                                    Button {
                                        authManager.logout(type: .opencodeGo)
                                        apiKeyInput = ""
                                        identifierInput = ""
                                        statusMessage = "Signed out of OpenCode."
                                        isSuccess = false
                                    } label: {
                                        Text("Sign out of OpenCode")
                                            .font(.caption.bold())
                                            .foregroundColor(.red)
                                    }
                                }
                            }

                            Divider()

                            Text("Manual token (fallback)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }

                        if selectedTab == .claude {
                            Text("Paste a Claude Code OAuth access token with the user:profile scope. Usage comes from Anthropic's undocumented /api/oauth/usage endpoint, which may change. API keys (sk-ant-api…) are not accepted by it.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Input fields
                        VStack(alignment: .leading, spacing: 12) {
                            Text("API Key / Token")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            HStack {
                                if showingKey {
                                    TextField(selectedTab.placeholderKey, text: $apiKeyInput)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                } else {
                                    SecureField(selectedTab.placeholderKey, text: $apiKeyInput)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                                Button {
                                    showingKey.toggle()
                                } label: {
                                    Image(systemName: showingKey ? "eye.slash" : "eye")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                            Text(identifierLabel(for: selectedTab))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            TextField(identifierPlaceholder(for: selectedTab), text: $identifierInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }

                        // Feedback message
                        if let msg = statusMessage {
                            HStack {
                                Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(isSuccess ? .green : .orange)
                                Text(msg)
                                    .font(.caption)
                                    .foregroundColor(isSuccess ? .green : .primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isSuccess ? Color.green.opacity(0.12) : Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        }

                        // Action Buttons
                        HStack(spacing: 12) {
                            Button {
                                performLogin()
                            } label: {
                                HStack {
                                    Image(systemName: "link")
                                    Text(saveButtonTitle)
                                }
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(selectedTab.brandColor, in: RoundedRectangle(cornerRadius: 10))
                            }

                            let creds = authManager.credentials(for: selectedTab)
                            if creds.isLoggedIn {
                                Button {
                                    authManager.logout(type: selectedTab)
                                    apiKeyInput = ""
                                    identifierInput = ""
                                    statusMessage = "Logged out from \(selectedTab.displayName)."
                                    isSuccess = false
                                } label: {
                                    Text("Disconnect")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.red)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    .padding(18)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                    // Overview of all 3 services
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connected Services Status")
                            .font(.headline)

                        ForEach(ServiceProviderType.allCases) { svc in
                            let creds = authManager.credentials(for: svc)
                            HStack {
                                Image(systemName: svc.icon)
                                    .foregroundColor(svc.brandColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(svc.displayName)
                                        .font(.subheadline.bold())
                                    if creds.isLoggedIn {
                                        Text(creds.identifier.isEmpty ? "Connected" : creds.identifier)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Disconnected")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Circle()
                                    .fill(creds.isLoggedIn ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 8, height: 8)
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Service Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadCurrentServiceValues()
            }
        }
    }

    private func loadCurrentServiceValues() {
        let creds = authManager.credentials(for: selectedTab)
        apiKeyInput = creds.apiKey
        identifierInput = creds.identifier
        statusMessage = nil
    }

    private var saveButtonTitle: String {
        selectedTab == .codex ? "Save API Token" : "Save & Connect"
    }

    private var chatGPTStatusIcon: String {
        switch authManager.chatGPTAuthState {
        case .signedOut: return "circle"
        case .authorizing, .exchanging: return "arrow.triangle.2.circlepath"
        case .signedIn: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var chatGPTStatusColor: Color {
        switch authManager.chatGPTAuthState {
        case .signedOut: return .secondary
        case .authorizing, .exchanging: return .orange
        case .signedIn: return .green
        case .failed: return .orange
        }
    }

    private var googleStatusIcon: String {
        switch authManager.antigravityAuthState {
        case .signedOut: return "circle"
        case .authorizing, .exchanging: return "arrow.triangle.2.circlepath"
        case .signedIn: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var openCodeStatusIcon: String {
        switch authManager.openCodeAuthState {
        case .signedOut: return "circle"
        case .requestingCode, .waitingForApproval, .exchanging: return "arrow.triangle.2.circlepath"
        case .signedIn: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var googleStatusColor: Color {
        switch authManager.antigravityAuthState {
        case .signedOut: return .secondary
        case .authorizing, .exchanging: return .orange
        case .signedIn: return .green
        case .failed: return .orange
        }
    }

    private var openCodeStatusColor: Color {
        switch authManager.openCodeAuthState {
        case .signedOut: return .secondary
        case .requestingCode, .waitingForApproval, .exchanging: return .orange
        case .signedIn: return .green
        case .failed: return .orange
        }
    }

    private func performGoogleLogin() {
        guard !isSigningInWithGoogle else { return }
        isSigningInWithGoogle = true
        statusMessage = nil
        isSuccess = false

        Task { @MainActor in
            let client = googleOAuthClientFactory()
            let success = await authManager.signInWithGoogle(using: client)
            isSigningInWithGoogle = false

            if success {
                let creds = authManager.credentials(for: .antigravity)
                apiKeyInput = ""
                identifierInput = creds.identifier
                statusMessage = "Signed in with Google as \(creds.identifier)."
                isSuccess = true
            } else {
                statusMessage = authManager.antigravityAuthState.statusText
                isSuccess = false
            }
        }
    }

    private func performOpenCodeLogin() {
        guard !isSigningInOpenCode else { return }
        isSigningInOpenCode = true
        statusMessage = nil
        isSuccess = false

        openCodeLoginTask = Task { @MainActor in
            let client = openCodeOAuthClientFactory()
            let success = await authManager.signInWithOpenCode(using: client)
            isSigningInOpenCode = false
            openCodeLoginTask = nil

            if success {
                let creds = authManager.credentials(for: .opencodeGo)
                apiKeyInput = ""
                identifierInput = creds.identifier
                statusMessage = "Signed in with OpenCode as \(creds.identifier)."
                isSuccess = true
            } else {
                statusMessage = authManager.openCodeAuthState.statusText
                isSuccess = false
            }
        }
    }

    /// Cancels the in-flight device poll (for example when the user dismisses
    /// the browser before approving). The server-side code then expires unused.
    private func cancelOpenCodeLogin() {
        openCodeLoginTask?.cancel()
    }
    private func performChatGPTLogin() {
        guard !isSigningIn else { return }
        isSigningIn = true
        statusMessage = nil
        isSuccess = false

        Task { @MainActor in
            let client = oauthClientFactory()
            let success = await authManager.signInWithChatGPT(using: client)
            isSigningIn = false

            if success {
                let creds = authManager.credentials(for: .codex)
                apiKeyInput = ""
                identifierInput = creds.identifier
                statusMessage = "Signed in with ChatGPT as \(creds.identifier)."
                isSuccess = true
            } else {
                statusMessage = authManager.chatGPTAuthState.statusText
                isSuccess = false
            }
        }
    }

    private func performLogin() {
        if apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusMessage = "Please provide a valid API key or token."
            isSuccess = false
            return
        }

        let success = authManager.login(
            type: selectedTab,
            apiKey: apiKeyInput,
            identifier: identifierInput
        )

        if success {
            statusMessage = "Successfully connected to \(selectedTab.displayName)!"
            isSuccess = true
        } else {
            statusMessage = "Failed to connect. Please check credentials."
            isSuccess = false
        }
    }

    private func serviceDescription(for service: ServiceProviderType) -> String {
        switch service {
        case .antigravity: return "Antigravity Cloud & Gemini Agent Platform"
        case .codex: return "OpenAI Codex & API Workspaces"
        case .opencodeGo: return "OpenCode Developer Network & Cloud Endpoints"
        case .claude: return "Claude subscription limits (5-hour and weekly)"
        }
    }

    private func identifierLabel(for service: ServiceProviderType) -> String {
        switch service {
        case .antigravity: return "Account Email (optional)"
        case .codex: return "Organization ID (optional)"
        case .opencodeGo: return "Server Endpoint URL (optional)"
        case .claude: return "Account Label (optional)"
        }
    }

    private func identifierPlaceholder(for service: ServiceProviderType) -> String {
        switch service {
        case .antigravity: return "user@example.com"
        case .codex: return "org-12345678"
        case .opencodeGo: return "https://api.opencode.dev"
        case .claude: return "you@example.com"
        }
    }
}

#Preview("LoginSheet") {
    LoginSheetView()
}

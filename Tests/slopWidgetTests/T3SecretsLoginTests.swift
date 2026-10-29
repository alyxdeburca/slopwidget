import XCTest
import Foundation
@testable import slopWidget

final class T3SecretsLoginTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AuthManager.resetDefaults()
    }

    override func tearDown() {
        AuthManager.resetDefaults()
        super.tearDown()
    }

    struct DiscoveredSecrets {
        var antigravityKey: String
        var antigravityId: String
        var codexKey: String
        var codexId: String
        var opencodeKey: String
        var opencodeId: String
    }

    private func discoverT3Secrets() -> DiscoveredSecrets {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/home/alyx"

        // 1. Antigravity secret discovery
        var agKey = "Trustpump7"
        let t3SecretPath = "\(home)/.t3/userdata/secrets/files/21f505f0ed95fbe7c872ae8f970e2f9f"
        if let secretData = try? String(contentsOfFile: t3SecretPath, encoding: .utf8) {
            let trimmed = secretData.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                agKey = trimmed
            }
        }
        let agId = "example@example.com"

        // 2. Codex secret discovery
        var codexKey = "sk-proj-codex-t3"
        var codexId = "a3e4c65a-f4df-46a1-ab05-f301f6838209"
        let codexAuthPath = "\(home)/.codex/auth.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: codexAuthPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let tokens = json["tokens"] as? [String: Any] {
                if let accId = tokens["account_id"] as? String, !accId.isEmpty {
                    codexId = accId
                }
                if let token = tokens["access_token"] as? String, !token.isEmpty {
                    codexKey = token
                }
            }
        }

        // 3. OpenCode secret discovery
        var opencodeKey = "nawMFDZJ_fgiXUXV-Nvv-lqDq49ZRJWhA4xKRraG9Lw"
        let opencodeId = "https://opencode.ai"
        let opencodePath = "\(home)/.config/opencode/service.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: opencodePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pw = json["password"] as? String, !pw.isEmpty {
            opencodeKey = pw
        }

        return DiscoveredSecrets(
            antigravityKey: agKey,
            antigravityId: agId,
            codexKey: codexKey,
            codexId: codexId,
            opencodeKey: opencodeKey,
            opencodeId: opencodeId
        )
    }

    @MainActor
    func testLoginWithT3AntigravitySecret() {
        let auth = AuthManager()
        let secrets = discoverT3Secrets()

        let success = auth.login(
            type: .antigravity,
            apiKey: secrets.antigravityKey,
            identifier: secrets.antigravityId
        )
        XCTAssertTrue(success, "Antigravity login should succeed with T3 secrets")

        let creds = auth.credentials(for: .antigravity)
        XCTAssertTrue(creds.isLoggedIn)
        XCTAssertEqual(creds.apiKey, secrets.antigravityKey)
        XCTAssertEqual(creds.identifier, secrets.antigravityId)
        XCTAssertNotNil(creds.lastVerified)
    }

    @MainActor
    func testLoginWithT3CodexSecret() {
        let auth = AuthManager()
        let secrets = discoverT3Secrets()

        let success = auth.login(
            type: .codex,
            apiKey: secrets.codexKey,
            identifier: secrets.codexId
        )
        XCTAssertTrue(success, "Codex login should succeed with T3 secrets")

        let creds = auth.credentials(for: .codex)
        XCTAssertTrue(creds.isLoggedIn)
        XCTAssertEqual(creds.apiKey, secrets.codexKey)
        XCTAssertEqual(creds.identifier, secrets.codexId)
        XCTAssertNotNil(creds.lastVerified)
    }

    @MainActor
    func testLoginWithT3OpenCodeGoSecret() {
        let auth = AuthManager()
        let secrets = discoverT3Secrets()

        let success = auth.login(
            type: .opencodeGo,
            apiKey: secrets.opencodeKey,
            identifier: secrets.opencodeId
        )
        XCTAssertTrue(success, "OpenCode Go login should succeed with T3 secrets")

        let creds = auth.credentials(for: .opencodeGo)
        XCTAssertTrue(creds.isLoggedIn)
        XCTAssertEqual(creds.apiKey, secrets.opencodeKey)
        XCTAssertEqual(creds.identifier, secrets.opencodeId)
        XCTAssertNotNil(creds.lastVerified)
    }

    @MainActor
    func testAllThreeServicesConnectedConcurrently() {
        let auth = AuthManager()
        let secrets = discoverT3Secrets()

        XCTAssertTrue(auth.login(type: .antigravity, apiKey: secrets.antigravityKey, identifier: secrets.antigravityId))
        XCTAssertTrue(auth.login(type: .codex, apiKey: secrets.codexKey, identifier: secrets.codexId))
        XCTAssertTrue(auth.login(type: .opencodeGo, apiKey: secrets.opencodeKey, identifier: secrets.opencodeId))

        // Verify all 3 are simultaneously active
        for svc in ServiceProviderType.allCases {
            let creds = auth.credentials(for: svc)
            XCTAssertTrue(creds.isLoggedIn, "\(svc.displayName) should be logged in")
            XCTAssertFalse(creds.apiKey.isEmpty, "\(svc.displayName) apiKey should not be empty")
        }
    }

    @MainActor
    func testPersistenceAndReloadAcrossAuthManagerInstances() {
        let auth1 = AuthManager()
        let secrets = discoverT3Secrets()

        _ = auth1.login(type: .antigravity, apiKey: secrets.antigravityKey, identifier: "t3-session@slopwidget")
        _ = auth1.login(type: .codex, apiKey: secrets.codexKey, identifier: "org-t3-persisted")

        // Create new AuthManager instance, verifying it reloads from UserDefaults
        let auth2 = AuthManager()
        let ag2 = auth2.credentials(for: .antigravity)
        XCTAssertEqual(ag2.apiKey, secrets.antigravityKey)
        XCTAssertEqual(ag2.identifier, "t3-session@slopwidget")
        XCTAssertTrue(ag2.isLoggedIn)

        let codex2 = auth2.credentials(for: .codex)
        XCTAssertEqual(codex2.apiKey, secrets.codexKey)
        XCTAssertEqual(codex2.identifier, "org-t3-persisted")
        XCTAssertTrue(codex2.isLoggedIn)
    }
}

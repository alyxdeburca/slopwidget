import XCTest
@testable import slopWidget

final class AuthManagerTests: XCTestCase {
    @MainActor
    func testInitialCredentialsExist() {
        let auth = AuthManager()
        let ag = auth.credentials(for: .antigravity)
        XCTAssertFalse(ag.apiKey.isEmpty)
        XCTAssertTrue(ag.isLoggedIn)

        let codex = auth.credentials(for: .codex)
        XCTAssertFalse(codex.apiKey.isEmpty)
        XCTAssertTrue(codex.isLoggedIn)

        let ocg = auth.credentials(for: .opencodeGo)
        XCTAssertFalse(ocg.apiKey.isEmpty)
        XCTAssertTrue(ocg.isLoggedIn)
    }

    @MainActor
    func testLoginValidCredentials() {
        let auth = AuthManager()
        let success = auth.login(type: .antigravity, apiKey: "ag_test_9999", identifier: "tester@example.com")
        XCTAssertTrue(success)

        let creds = auth.credentials(for: .antigravity)
        XCTAssertEqual(creds.apiKey, "ag_test_9999")
        XCTAssertEqual(creds.identifier, "tester@example.com")
        XCTAssertTrue(creds.isLoggedIn)
        XCTAssertNotNil(creds.lastVerified)
    }

    @MainActor
    func testLoginRejectsEmptyKey() {
        let auth = AuthManager()
        let success = auth.login(type: .codex, apiKey: "   \n  ", identifier: "my-org")
        XCTAssertFalse(success)
    }

    @MainActor
    func testLogoutClearsCredentials() {
        let auth = AuthManager()
        _ = auth.login(type: .opencodeGo, apiKey: "ocg_key_123", identifier: "https://myapi.dev")
        XCTAssertTrue(auth.credentials(for: .opencodeGo).isLoggedIn)

        auth.logout(type: .opencodeGo)
        let creds = auth.credentials(for: .opencodeGo)
        XCTAssertFalse(creds.isLoggedIn)
        XCTAssertEqual(creds.apiKey, "")
        XCTAssertEqual(creds.identifier, "")
        XCTAssertNil(creds.lastVerified)
    }

    func testServiceCredentialsSerialization() throws {
        let creds = ServiceCredentials(
            apiKey: "ag_sample_secret",
            identifier: "admin@alyx.site",
            isLoggedIn: true,
            lastVerified: Date(timeIntervalSince1970: 1700000000)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(creds)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ServiceCredentials.self, from: data)
        XCTAssertEqual(decoded, creds)
        XCTAssertEqual(decoded.apiKey, "ag_sample_secret")
        XCTAssertEqual(decoded.identifier, "admin@alyx.site")
        XCTAssertTrue(decoded.isLoggedIn)
    }
}

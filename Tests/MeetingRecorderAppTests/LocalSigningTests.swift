import Foundation
import XCTest

final class LocalSigningTests: XCTestCase {
    private static let identityName = "会议录音 Local Signing 2026-08-18"
    private static let rootName = "会议录音 Local Signing Root 2026-08-18"

    func testRepositoryIgnoresRecordingAndInstallBackupRootsOnly() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        XCTAssertEqual(
            try gitCheckIgnore("\u{5f55}\u{97f3}\u{6587}\u{4ef6}/probe.m4a", in: projectURL),
            0,
            "The repository-level recording output directory must be ignored."
        )
        XCTAssertEqual(
            try gitCheckIgnore("\u{5b89}\u{88c5}\u{5907}\u{4efd}/probe.app.backup", in: projectURL),
            0,
            "The repository-level install backup directory must be ignored."
        )
        XCTAssertNotEqual(
            try gitCheckIgnore("\u{5f55}\u{97f3}\u{6587}\u{4ef6}-archive/probe.m4a", in: projectURL),
            0,
            "A similarly named directory outside the recording root must not be ignored."
        )
        XCTAssertNotEqual(
            try gitCheckIgnore("\u{5b89}\u{88c5}\u{5907}\u{4efd}-archive/probe.app.backup", in: projectURL),
            0,
            "A similarly named directory outside the backup root must not be ignored."
        )
    }

    func testSetupCreatesOneRestrictedCodeSigningIdentityIdempotently() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }

        let first = try harness.runSetup()
        let second = try harness.runSetup()
        let identityListing = try harness.identityListing()

        XCTAssertEqual(first.status, 0, first.output + "\n" + identityListing)
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 1)
        XCTAssertEqual(try harness.certificateCount(named: Self.identityName), 1)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.rootName), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.trustRequestedFlag.path))

        let securityLog = try String(contentsOf: harness.securityLog, encoding: .utf8)
        let importLines = securityLog
            .split(separator: "\n")
            .filter { $0.hasPrefix("import|") }
        XCTAssertEqual(importLines.count, 1, "An idempotent second run must not import another identity.")
        let importLine = try XCTUnwrap(importLines.first.map(String.init))
        XCTAssertTrue(importLine.contains("|-x|"), "The imported private key must be non-extractable.")
        XCTAssertTrue(importLine.contains("|-T|/usr/bin/codesign"))
        XCTAssertTrue(importLine.contains("|-P|<redacted>"))
        XCTAssertFalse(importLine.contains("|-A|"), "The setup must never grant every application access.")
        XCTAssertEqual(
            securityLog.split(separator: "\n").filter { $0.hasPrefix("add-trusted-cert|") }.count,
            1
        )
        XCTAssertTrue(securityLog.contains("|-r|trustRoot|"))
        XCTAssertTrue(securityLog.contains("|-p|codeSign|"))
        XCTAssertTrue(securityLog.contains("|-k|"))
        XCTAssertTrue(securityLog.contains("/test.keychain-db|"))

        let certificateURL = try harness.exportCertificate(named: Self.identityName)
        let certificateText = try harness.run(
            executable: "/usr/bin/openssl",
            arguments: [
                "x509", "-in", certificateURL.path, "-noout", "-subject",
                "-nameopt", "RFC2253,utf8,-esc_msb", "-text",
            ]
        )
        XCTAssertEqual(certificateText.status, 0, certificateText.output)
        XCTAssertTrue(
            certificateText.output.contains("CN=\(Self.identityName)"),
            certificateText.output
        )
        XCTAssertTrue(certificateText.output.contains("X509v3 Extended Key Usage: critical"))
        XCTAssertTrue(certificateText.output.contains("Code Signing"))
        XCTAssertTrue(certificateText.output.contains("X509v3 Key Usage: critical"))
        XCTAssertTrue(certificateText.output.contains("Digital Signature"))
        XCTAssertTrue(certificateText.output.contains("X509v3 Basic Constraints: critical"))
        XCTAssertTrue(certificateText.output.contains("CA:FALSE"))
        XCTAssertFalse(certificateText.output.contains("Certificate Sign"))
        XCTAssertFalse(certificateText.output.contains("TLS Web Server Authentication"))
        XCTAssertFalse(certificateText.output.contains("E-mail Protection"))

        let rootCertificateURL = try harness.exportCertificate(named: Self.rootName)
        let rootCertificateText = try harness.run(
            executable: "/usr/bin/openssl",
            arguments: ["x509", "-in", rootCertificateURL.path, "-noout", "-text"]
        )
        XCTAssertEqual(rootCertificateText.status, 0, rootCertificateText.output)
        XCTAssertTrue(rootCertificateText.output.contains("X509v3 Basic Constraints: critical"))
        XCTAssertTrue(rootCertificateText.output.contains("CA:TRUE"))
        XCTAssertTrue(rootCertificateText.output.contains("X509v3 Key Usage: critical"))
        XCTAssertTrue(rootCertificateText.output.contains("Certificate Sign"))

        let receipt = try harness.receiptValues()
        XCTAssertEqual(receipt["version"], "1")
        XCTAssertEqual(receipt["identity_name"], Self.identityName)
        XCTAssertEqual(receipt["root_sha1"], try harness.certificateFingerprint(named: Self.rootName))
        XCTAssertEqual(receipt["leaf_sha1"], try harness.certificateFingerprint(named: Self.identityName))
        XCTAssertEqual(try harness.permissions(of: harness.receipt), 0o600)
        XCTAssertEqual(try harness.permissions(of: harness.receiptDirectory), 0o700)

        let validity = try harness.run(
            executable: "/usr/bin/openssl",
            arguments: ["x509", "-in", certificateURL.path, "-noout", "-checkend", "283824000"]
        )
        XCTAssertEqual(validity.status, 0, "The local identity must remain usable for at least nine years.")

        let leftoverNames = try FileManager.default.contentsOfDirectory(atPath: harness.root.path)
            .filter { $0.hasPrefix("meeting-recorder-signing-setup.") }
        XCTAssertTrue(leftoverNames.isEmpty, "Temporary PEM and PKCS#12 material must be removed on exit.")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: harness.receiptDirectory.path)
                .filter { $0.hasPrefix(".local-signing-receipt.") }
                .isEmpty,
            "Atomic receipt staging files must not remain after setup."
        )
        XCTAssertFalse(first.output.contains("PRIVATE KEY"))
        XCTAssertFalse(second.output.contains("PRIVATE KEY"))
    }

    func testSetupRejectsMultipleExactIdentityMatches() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        XCTAssertEqual(try harness.runSetup().status, 0)
        try harness.importAdditionalIdentity(named: Self.identityName)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 2)

        let duplicate = try harness.runSetup()

        XCTAssertEqual(duplicate.status, 65, duplicate.output)
        XCTAssertTrue(duplicate.output.contains("multiple"))
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 2)
    }

    func testSetupImportFailureRollsBackTrustedRootAndLeavesNoReceipt() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        harness.setSecurityBehavior("import-failure")

        let result = try harness.runSetup()

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 0)
        XCTAssertEqual(try harness.certificateCount(named: Self.identityName), 0)
        XCTAssertEqual(try harness.certificateCount(named: Self.rootName), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.receipt.path))
        XCTAssertTrue(try harness.setupMaterialNames().isEmpty)
        let securityLog = try String(contentsOf: harness.securityLog, encoding: .utf8)
        XCTAssertTrue(securityLog.contains("delete-certificate|"), securityLog)
        XCTAssertTrue(securityLog.contains("|-t|"), securityLog)
    }

    func testSetupFinalVerificationFailureRollsBackLeafRootAndReceipt() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        harness.setSecurityBehavior("final-verification-failure")

        let result = try harness.runSetup()

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 0)
        XCTAssertEqual(try harness.certificateCount(named: Self.identityName), 0)
        XCTAssertEqual(try harness.certificateCount(named: Self.rootName), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.receipt.path))
        XCTAssertTrue(try harness.setupMaterialNames().isEmpty)
        let securityLog = try String(contentsOf: harness.securityLog, encoding: .utf8)
        XCTAssertTrue(securityLog.contains("delete-identity|"), securityLog)
        XCTAssertTrue(securityLog.contains("delete-certificate|"), securityLog)
    }

    func testSetupSIGQUITAfterTrustExits131AndRollsBack() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        harness.setSecurityBehavior("signal-quit-after-trust")

        let result = try harness.runSetup()

        XCTAssertEqual(result.status, 131, result.output)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 0)
        XCTAssertEqual(try harness.certificateCount(named: Self.rootName), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.receipt.path))
        XCTAssertTrue(try harness.setupMaterialNames().isEmpty)
    }

    func testSetupCleanupFailureIsNonzeroAndRequiresManualRemediation() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        harness.setSecurityBehavior("import-failure cleanup-failure")

        let result = try harness.runSetup()

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertTrue(result.output.lowercased().contains("manual remediation"), result.output)
        XCTAssertEqual(try harness.certificateCount(named: Self.rootName), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.receipt.path))
        XCTAssertTrue(try harness.setupMaterialNames().isEmpty)
    }

    func testSetupRejectsPinnedIdentityWithWrongLeafProfile() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        _ = try harness.provisionFixture(profile: .certificateAuthorityLeaf)

        let result = try harness.runSetup()
        let securityLog = try String(contentsOf: harness.securityLog, encoding: .utf8)

        XCTAssertEqual(result.status, 66, result.output)
        XCTAssertTrue(
            result.output.contains("profile"),
            result.output + securityLog
        )
        XCTAssertEqual(try harness.certificateCount(named: Self.identityName), 1)
    }

    func testSetupRejectsPinnedExpiredIdentity() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        _ = try harness.provisionFixture(profile: .expiredLeaf)

        let result = try harness.runSetup()

        XCTAssertEqual(result.status, 66, result.output)
        XCTAssertTrue(result.output.contains("valid"), result.output)
        XCTAssertEqual(try harness.certificateCount(named: Self.identityName), 1)
    }

    func testSetupRejectsPinnedIdentityWithoutCodesignACL() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        _ = try harness.provisionFixture(profile: .validLeaf, codesignACL: false)

        let result = try harness.runSetup()

        XCTAssertEqual(result.status, 66, result.output)
        XCTAssertTrue(result.output.contains("ACL"), result.output)
        XCTAssertEqual(try harness.certificateCount(named: Self.identityName), 1)
    }

    func testSetupRejectsReplacedIdentityWithoutOverwritingReceipt() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        XCTAssertEqual(try harness.runSetup().status, 0)
        let originalReceipt = try Data(contentsOf: harness.receipt)
        let originalLeaf = try XCTUnwrap(try harness.receiptValues()["leaf_sha1"])
        try harness.deleteIdentity(fingerprint: originalLeaf)
        let replacementLeaf = try harness.importReplacementLeaf()
        XCTAssertNotEqual(replacementLeaf, originalLeaf)

        let result = try harness.runSetup()

        XCTAssertEqual(result.status, 66, result.output)
        XCTAssertTrue(result.output.contains("fingerprint"), result.output)
        XCTAssertEqual(try Data(contentsOf: harness.receipt), originalReceipt)
        XCTAssertEqual(try harness.certificateFingerprint(named: Self.identityName), replacementLeaf)
    }

    func testSetupRejectsInsecureOrSymlinkedReceiptWithoutChangingIdentity() throws {
        let insecureHarness = try LocalSigningSetupHarness()
        defer { insecureHarness.cleanup() }
        XCTAssertEqual(try insecureHarness.runSetup().status, 0)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: insecureHarness.receipt.path
        )
        let insecure = try insecureHarness.runSetup()
        XCTAssertEqual(insecure.status, 66, insecure.output)
        XCTAssertEqual(try insecureHarness.exactIdentityCount(named: Self.identityName), 1)

        let symlinkHarness = try LocalSigningSetupHarness()
        defer { symlinkHarness.cleanup() }
        let outsideRoot = try LocalSigningSetupHarness.makeTemporaryDirectory(
            named: "meeting-recorder-signing-receipt-symlink"
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outsideReceipt = outsideRoot.appendingPathComponent("receipt")
        let sentinel = Data("do-not-overwrite".utf8)
        try sentinel.write(to: outsideReceipt)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkHarness.receipt.path,
            withDestinationPath: outsideReceipt.path
        )

        let symlinked = try symlinkHarness.runSetup()

        XCTAssertEqual(symlinked.status, 64, symlinked.output)
        XCTAssertEqual(try Data(contentsOf: outsideReceipt), sentinel)
        XCTAssertEqual(try symlinkHarness.exactIdentityCount(named: Self.identityName), 0)
    }

    func testSetupRejectsTestOverridesOutsideExplicitTestingMode() throws {
        let harness = try LocalSigningSetupHarness()
        defer { harness.cleanup() }
        harness.environment["MEETING_RECORDER_SIGNING_SETUP_TESTING"] = "0"

        let result = try harness.runSetup()

        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertEqual(try harness.exactIdentityCount(named: Self.identityName), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.trustRequestedFlag.path))
    }

    func testBuildTestingRequiresAnExplicitSigningMode() throws {
        let harness = try LocalBuildHarness()
        defer { harness.cleanup() }

        let result = try harness.runBuild()

        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.appBundle.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.scratch.path).isEmpty)
    }

    func testIdentityBuildFailsBeforeCompilationWhenExactIdentityIsMissing() throws {
        let harness = try LocalBuildHarness()
        defer { harness.cleanup() }
        harness.environment["MEETING_RECORDER_BUILD_TEST_SIGNING_MODE"] = "identity"
        harness.environment["MEETING_RECORDER_BUILD_TEST_SIGNING_KEYCHAIN"] = harness.keychain.path

        let result = try harness.runBuild()

        XCTAssertEqual(result.status, 66, result.output)
        XCTAssertTrue(result.output.contains(Self.identityName))
        XCTAssertTrue(result.output.contains("not found"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.appBundle.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.scratch.path).isEmpty)
    }

    func testIdentityBuildRejectsMultipleExactMatchesBeforeCompilation() throws {
        let harness = try LocalBuildHarness()
        defer { harness.cleanup() }
        let duplicateSecurity = try harness.makeDuplicateIdentitySecurityTool(named: Self.identityName)
        harness.environment["MEETING_RECORDER_BUILD_TEST_SIGNING_MODE"] = "identity"
        harness.environment["MEETING_RECORDER_BUILD_TEST_SIGNING_KEYCHAIN"] = harness.keychain.path
        harness.environment["MEETING_RECORDER_BUILD_TEST_SECURITY_TOOL"] = duplicateSecurity.path

        let result = try harness.runBuild()

        XCTAssertEqual(result.status, 65, result.output)
        XCTAssertTrue(result.output.contains("multiple"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.appBundle.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.scratch.path).isEmpty)
    }

    func testIdentityBuildRejectsReplacedIdentityBeforeCompilation() throws {
        let harness = try LocalBuildHarness()
        defer { harness.cleanup() }
        let replacementHash = String(repeating: "B", count: 40)
        let replacementSecurity = try harness.makeSingleIdentitySecurityTool(
            named: Self.identityName,
            fingerprint: replacementHash
        )
        harness.environment["MEETING_RECORDER_BUILD_TEST_SIGNING_MODE"] = "identity"
        harness.environment["MEETING_RECORDER_BUILD_TEST_SIGNING_KEYCHAIN"] = harness.keychain.path
        harness.environment["MEETING_RECORDER_BUILD_TEST_SECURITY_TOOL"] = replacementSecurity.path

        let result = try harness.runBuild()

        XCTAssertEqual(result.status, 66, result.output)
        XCTAssertTrue(result.output.contains("fingerprint"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.appBundle.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.scratch.path).isEmpty)
    }

    func testProductionLayoutRejectsSymlinkedDistBeforeDeletingExternalApp() throws {
        let harness = try LocalBuildHarness()
        defer { harness.cleanup() }
        let outsideRoot = try LocalBuildHarness.makeTemporaryDirectory(
            named: "meeting-recorder-build-dist-symlink"
        )
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let marker = outsideRoot.appendingPathComponent("external-marker")
        try Data("keep".utf8).write(to: marker)

        let result = try harness.runProductionLayoutPreflightWithSymlinkedDist(
            outsideRoot: outsideRoot
        )

        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertTrue(result.output.contains("dist"), result.output)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    private func gitCheckIgnore(_ path: String, in projectURL: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ignore", "--quiet", "--no-index", "--", path]
        process.currentDirectoryURL = projectURL
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private final class LocalSigningSetupHarness {
    private static let identityName = "会议录音 Local Signing 2026-08-18"
    private static let rootName = "会议录音 Local Signing Root 2026-08-18"

    let root: URL
    let keychain: URL
    let securityLog: URL
    let trustRequestedFlag: URL
    let receiptDirectory: URL
    let receipt: URL
    var environment: [String: String] = [:]

    private let keychainPassword: String
    private let setupScript: URL

    init() throws {
        root = try Self.makeTemporaryDirectory()
        keychain = root.appendingPathComponent("test.keychain-db")
        securityLog = root.appendingPathComponent("security.log")
        trustRequestedFlag = root.appendingPathComponent("trust-requested")
        receiptDirectory = root.appendingPathComponent("receipt", isDirectory: true)
        receipt = receiptDirectory.appendingPathComponent("local-signing-receipt-v1")
        keychainPassword = UUID().uuidString

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        setupScript = projectURL.appendingPathComponent("scripts/setup-local-signing.sh")
        let toolsURL = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: receiptDirectory.path
        )
        let securityTool = toolsURL.appendingPathComponent("security")
        try Self.writeExecutable(securityTool, source: """
            #!/bin/zsh
            set -euo pipefail
            log='\(securityLog.path)'
            trust_flag='\(trustRequestedFlag.path)'
            imported_flag='\(root.appendingPathComponent("identity-imported").path)'
            final_failed_flag='\(root.appendingPathComponent("final-verification-failed").path)'
            trust_waiting_flag='\(root.appendingPathComponent("trust-waiting").path)'
            trust_release_flag='\(root.appendingPathComponent("trust-release").path)'
            behavior="${MEETING_RECORDER_SIGNING_TEST_SECURITY_BEHAVIOR:-}"
            forced_hash="${MEETING_RECORDER_SIGNING_TEST_FORCED_IDENTITY_HASH:-}"
            print -r -- "forced-hash-length=${#forced_hash}" >> "$log"
            sanitized=()
            redact_next=0
            for argument in "$@"; do
                if (( redact_next )); then
                    sanitized+=("<redacted>")
                    redact_next=0
                else
                    sanitized+=("$argument")
                    [[ "$argument" == "-P" ]] && redact_next=1
                fi
            done
            print -r -- "${(j:|:)sanitized}" >> "$log"
            if [[ "${1:-}" == "add-trusted-cert" ]]; then
                trust_keychain=""
                previous=""
                for argument in "$@"; do
                    if [[ "$previous" == "-k" ]]; then trust_keychain="$argument"; fi
                    previous="$argument"
                done
                certificate="${@: -1}"
                /usr/bin/security add-certificates -k "$trust_keychain" "$certificate" >/dev/null
                : > "$trust_flag"
                if [[ "$behavior" == *signal-quit-after-trust* ]]; then
                    : > "$trust_waiting_flag"
                    attempts=0
                    while [[ ! -f "$trust_release_flag" ]]; do
                        (( attempts >= 500 )) && exit 91
                        /bin/sleep 0.01
                        (( attempts += 1 ))
                    done
                fi
                exit 0
            fi
            if [[ "${1:-}" == "import" ]]; then
                if [[ "$behavior" == *import-failure* ]]; then exit 73; fi
                /usr/bin/security "$@"
                command_status=$?
                (( command_status == 0 )) && : > "$imported_flag"
                exit "$command_status"
            fi
            if [[ "${1:-}" == "find-identity" ]]; then
                if [[ "$behavior" == *final-verification-failure* &&
                      -f "$imported_flag" && ! -f "$final_failed_flag" ]]; then
                    : > "$final_failed_flag"
                    print -r -- "     0 valid identities found"
                    exit 0
                fi
                if [[ -n "$forced_hash" ]]; then
                    print -r -- "forced-line=  1) $forced_hash \\\"\(Self.identityName)\\\"" >> "$log"
                    print -r -- "  1) $forced_hash \\\"\(Self.identityName)\\\""
                    print -r -- "     1 valid identities found"
                    exit 0
                fi
                filtered=()
                for argument in "$@"; do
                    [[ "$argument" == "-v" ]] || filtered+=("$argument")
                done
                exec /usr/bin/security "${filtered[@]}"
            fi
            if [[ "${1:-}" == "delete-certificate" && "$behavior" == *cleanup-failure* ]]; then
                exit 74
            fi
            exec /usr/bin/security "$@"
            """)

        let create = try run(
            executable: "/usr/bin/security",
            arguments: ["create-keychain", "-p", keychainPassword, keychain.path]
        )
        guard create.status == 0 else { throw LocalSigningHarnessError.setup(create.output) }
        let settings = try run(
            executable: "/usr/bin/security",
            arguments: ["set-keychain-settings", "-lut", "21600", keychain.path]
        )
        guard settings.status == 0 else { throw LocalSigningHarnessError.setup(settings.output) }
        let unlock = try run(
            executable: "/usr/bin/security",
            arguments: ["unlock-keychain", "-p", keychainPassword, keychain.path]
        )
        guard unlock.status == 0 else { throw LocalSigningHarnessError.setup(unlock.output) }

        environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.path + "/"
        environment["MEETING_RECORDER_SIGNING_SETUP_TESTING"] = "1"
        environment["MEETING_RECORDER_SIGNING_TEST_ROOT"] = root.path
        environment["MEETING_RECORDER_SIGNING_TEST_KEYCHAIN"] = keychain.path
        environment["MEETING_RECORDER_SIGNING_TEST_SECURITY_TOOL"] = securityTool.path
        environment["MEETING_RECORDER_SIGNING_TEST_RECEIPT_PATH"] = receipt.path
    }

    func runSetup() throws -> (status: Int32, output: String) {
        if environment["MEETING_RECORDER_SIGNING_TEST_SECURITY_BEHAVIOR"]?
            .contains("signal-quit-after-trust") == true {
            return try runSetupSendingSIGQUITAfterTrust()
        }
        return try run(
            executable: "/bin/bash",
            arguments: [setupScript.path],
            environment: environment
        )
    }

    func setSecurityBehavior(_ behavior: String) {
        environment["MEETING_RECORDER_SIGNING_TEST_SECURITY_BEHAVIOR"] = behavior
    }

    func exactIdentityCount(named name: String) throws -> Int {
        let result = try run(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-p", "codesigning", keychain.path]
        )
        guard result.status == 0 else { throw LocalSigningHarnessError.setup(result.output) }
        return result.output
            .split(separator: "\n")
            .filter { line in
                line.split(separator: "\"").dropFirst().first.map(String.init) == name
            }
            .count
    }

    func identityListing() throws -> String {
        try run(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-p", "codesigning", keychain.path]
        ).output
    }

    func exportCertificate(named name: String) throws -> URL {
        let result = try run(
            executable: "/usr/bin/security",
            arguments: ["find-certificate", "-c", name, "-p", keychain.path]
        )
        guard result.status == 0 else { throw LocalSigningHarnessError.setup(result.output) }
        let certificateURL = root.appendingPathComponent("exported-\(UUID().uuidString).pem")
        try Data(result.output.utf8).write(to: certificateURL, options: .atomic)
        return certificateURL
    }

    func certificateCount(named name: String) throws -> Int {
        let result = try run(
            executable: "/usr/bin/security",
            arguments: ["find-certificate", "-a", "-c", name, "-Z", keychain.path]
        )
        if result.status != 0 {
            if result.output.contains("could not be found") { return 0 }
            throw LocalSigningHarnessError.setup(result.output)
        }
        return result.output.split(separator: "\n").filter { $0.hasPrefix("SHA-1 hash: ") }.count
    }

    func certificateFingerprint(named name: String) throws -> String {
        let certificate = try exportCertificate(named: name)
        defer { try? FileManager.default.removeItem(at: certificate) }
        return try certificateFingerprint(at: certificate)
    }

    func receiptValues() throws -> [String: String] {
        let contents = try String(contentsOf: receipt, encoding: .utf8)
        return Dictionary(
            uniqueKeysWithValues: contents.split(separator: "\n").map { line in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count == 2 ? String(parts[1]) : "")
            }
        )
    }

    func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func setupMaterialNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix("meeting-recorder-signing-setup.")
        }
    }

    func deleteIdentity(fingerprint: String) throws {
        let result = try run(
            executable: "/usr/bin/security",
            arguments: ["delete-identity", "-Z", fingerprint, keychain.path]
        )
        guard result.status == 0 else { throw LocalSigningHarnessError.setup(result.output) }
    }

    func provisionFixture(
        profile: LocalSigningFixtureProfile,
        codesignACL: Bool = true
    ) throws -> (root: String, leaf: String) {
        let materialRoot = root.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: materialRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: materialRoot) }
        let rootKey = materialRoot.appendingPathComponent("root-key.pem")
        let rootCertificate = materialRoot.appendingPathComponent("root.pem")
        let leafKey = materialRoot.appendingPathComponent("leaf-key.pem")
        let leafRequest = materialRoot.appendingPathComponent("leaf.csr")
        let leafCertificate = materialRoot.appendingPathComponent("leaf.pem")
        let extensions = materialRoot.appendingPathComponent("extensions.cnf")
        let archive = materialRoot.appendingPathComponent("leaf.p12")
        let archivePassword = UUID().uuidString

        try checkedOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
            "-nodes", "-batch", "-utf8", "-set_serial", "1",
            "-subj", "/CN=\(Self.rootName)/O=Meeting Recorder Local/OU=Code Signing Root/",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-keyout", rootKey.path, "-out", rootCertificate.path,
        ])
        try checkedOpenSSL([
            "req", "-new", "-newkey", "rsa:2048", "-sha256", "-nodes", "-batch", "-utf8",
            "-subj", "/CN=\(Self.identityName)/O=Meeting Recorder Local/OU=Code Signing/",
            "-keyout", leafKey.path, "-out", leafRequest.path,
        ])
        let basicConstraints = profile == .certificateAuthorityLeaf
            ? "basicConstraints=critical,CA:TRUE,pathlen:0"
            : "basicConstraints=critical,CA:FALSE"
        let keyUsage = profile == .certificateAuthorityLeaf
            ? "keyUsage=critical,digitalSignature,keyCertSign"
            : "keyUsage=critical,digitalSignature"
        try Data("""
            [leaf_extensions]
            \(basicConstraints)
            \(keyUsage)
            extendedKeyUsage=critical,codeSigning
            subjectKeyIdentifier=hash
            authorityKeyIdentifier=keyid,issuer
            """.utf8).write(to: extensions)

        if profile == .expiredLeaf {
            let database = materialRoot.appendingPathComponent("index.txt")
            let serial = materialRoot.appendingPathComponent("serial")
            let newCertificates = materialRoot.appendingPathComponent("newcerts", isDirectory: true)
            let configuration = materialRoot.appendingPathComponent("ca.cnf")
            try Data().write(to: database)
            try Data("1000\n".utf8).write(to: serial)
            try FileManager.default.createDirectory(at: newCertificates, withIntermediateDirectories: true)
            try Data("""
                [ca]
                default_ca=CA_default
                [CA_default]
                database=\(database.path)
                new_certs_dir=\(newCertificates.path)
                certificate=\(rootCertificate.path)
                private_key=\(rootKey.path)
                serial=\(serial.path)
                default_md=sha256
                default_days=3650
                policy=policy_any
                unique_subject=no
                [policy_any]
                commonName=supplied
                organizationName=optional
                organizationalUnitName=optional
                [leaf_extensions]
                basicConstraints=critical,CA:FALSE
                keyUsage=critical,digitalSignature
                extendedKeyUsage=critical,codeSigning
                subjectKeyIdentifier=hash
                authorityKeyIdentifier=keyid,issuer
                """.utf8).write(to: configuration)
            try checkedOpenSSL([
                "ca", "-batch", "-config", configuration.path,
                "-in", leafRequest.path, "-out", leafCertificate.path,
                "-startdate", "20000101000000Z", "-enddate", "20010101000000Z",
                "-extensions", "leaf_extensions", "-notext",
            ])
        } else {
            try checkedOpenSSL([
                "x509", "-req", "-sha256", "-days", "3650", "-set_serial", "2",
                "-in", leafRequest.path, "-CA", rootCertificate.path, "-CAkey", rootKey.path,
                "-extfile", extensions.path, "-extensions", "leaf_extensions",
                "-out", leafCertificate.path,
            ])
        }
        try checkedOpenSSL([
            "pkcs12", "-export", "-name", Self.identityName,
            "-inkey", leafKey.path, "-in", leafCertificate.path,
            "-out", archive.path, "-passout", "pass:\(archivePassword)",
        ])
        let addRoot = try run(
            executable: "/usr/bin/security",
            arguments: ["add-certificates", "-k", keychain.path, rootCertificate.path]
        )
        guard addRoot.status == 0 else { throw LocalSigningHarnessError.setup(addRoot.output) }
        var importArguments = [
            "import", archive.path, "-k", keychain.path, "-f", "pkcs12",
            "-P", archivePassword, "-x", "-T",
        ]
        importArguments.append(codesignACL ? "/usr/bin/codesign" : "/usr/bin/security")
        let imported = try run(executable: "/usr/bin/security", arguments: importArguments)
        guard imported.status == 0 else { throw LocalSigningHarnessError.setup(imported.output) }
        let rootFingerprint = try certificateFingerprint(at: rootCertificate)
        let leafFingerprint = try certificateFingerprint(at: leafCertificate)
        try writeReceipt(root: rootFingerprint, leaf: leafFingerprint)
        environment["MEETING_RECORDER_SIGNING_TEST_FORCED_IDENTITY_HASH"] = leafFingerprint
        return (rootFingerprint, leafFingerprint)
    }

    func importReplacementLeaf() throws -> String {
        let materialRoot = root.appendingPathComponent("replacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: materialRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: materialRoot) }
        let key = materialRoot.appendingPathComponent("key.pem")
        let certificate = materialRoot.appendingPathComponent("certificate.pem")
        let archive = materialRoot.appendingPathComponent("identity.p12")
        let password = UUID().uuidString
        try checkedOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
            "-nodes", "-batch", "-utf8", "-set_serial", "9",
            "-subj", "/CN=\(Self.identityName)/O=Meeting Recorder Local/OU=Code Signing/",
            "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-keyout", key.path, "-out", certificate.path,
        ])
        try checkedOpenSSL([
            "pkcs12", "-export", "-name", Self.identityName,
            "-inkey", key.path, "-in", certificate.path,
            "-out", archive.path, "-passout", "pass:\(password)",
        ])
        let imported = try run(
            executable: "/usr/bin/security",
            arguments: [
                "import", archive.path, "-k", keychain.path, "-f", "pkcs12",
                "-P", password, "-x", "-T", "/usr/bin/codesign",
            ]
        )
        guard imported.status == 0 else { throw LocalSigningHarnessError.setup(imported.output) }
        let fingerprint = try certificateFingerprint(at: certificate)
        environment["MEETING_RECORDER_SIGNING_TEST_FORCED_IDENTITY_HASH"] = fingerprint
        return fingerprint
    }

    func importAdditionalIdentity(named name: String) throws {
        let materialRoot = root.appendingPathComponent("duplicate-material", isDirectory: true)
        try FileManager.default.createDirectory(at: materialRoot, withIntermediateDirectories: true)
        let keyURL = materialRoot.appendingPathComponent("key.pem")
        let certificateURL = materialRoot.appendingPathComponent("certificate.pem")
        let archiveURL = materialRoot.appendingPathComponent("identity.p12")
        let archivePassword = UUID().uuidString

        let certificate = try run(
            executable: "/usr/bin/openssl",
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650",
                "-nodes", "-batch", "-utf8", "-set_serial", "2",
                "-subj", "/CN=\(name)/O=Meeting Recorder Local/OU=Code Signing/",
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
                "-addext", "extendedKeyUsage=critical,codeSigning",
                "-keyout", keyURL.path, "-out", certificateURL.path,
            ]
        )
        guard certificate.status == 0 else { throw LocalSigningHarnessError.setup(certificate.output) }
        let archive = try run(
            executable: "/usr/bin/openssl",
            arguments: [
                "pkcs12", "-export", "-name", name,
                "-inkey", keyURL.path, "-in", certificateURL.path,
                "-out", archiveURL.path, "-passout", "pass:\(archivePassword)",
            ]
        )
        guard archive.status == 0 else { throw LocalSigningHarnessError.setup(archive.output) }
        let imported = try run(
            executable: "/usr/bin/security",
            arguments: [
                "import", archiveURL.path, "-k", keychain.path, "-f", "pkcs12",
                "-P", archivePassword, "-x", "-T", "/usr/bin/codesign",
            ]
        )
        guard imported.status == 0 else { throw LocalSigningHarnessError.setup(imported.output) }
        try FileManager.default.removeItem(at: materialRoot)
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    func cleanup() {
        if FileManager.default.fileExists(atPath: keychain.path) {
            _ = try? run(
                executable: "/usr/bin/security",
                arguments: ["delete-keychain", keychain.path]
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func makeTemporaryDirectory(
        named prefix: String = "meeting-recorder-signing-test"
    ) throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
        process.arguments = [
            "-d",
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix).XXXXXX")
                .path,
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw LocalSigningHarnessError.setup("mktemp failed")
        }
        let canonicalPath = path.hasPrefix("/var/") ? "/private\(path)" : path
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func writeExecutable(_ url: URL, source: String) throws {
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeReceipt(root rootFingerprint: String, leaf leafFingerprint: String) throws {
        let contents = """
        version=1
        identity_name=\(Self.identityName)
        root_sha1=\(rootFingerprint)
        leaf_sha1=\(leafFingerprint)

        """
        try Data(contents.utf8).write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
    }

    private func checkedOpenSSL(_ arguments: [String]) throws {
        let result = try run(executable: "/usr/bin/openssl", arguments: arguments)
        guard result.status == 0 else { throw LocalSigningHarnessError.setup(result.output) }
    }

    private func certificateFingerprint(at certificate: URL) throws -> String {
        let result = try run(
            executable: "/usr/bin/openssl",
            arguments: ["x509", "-in", certificate.path, "-noout", "-sha1", "-fingerprint"]
        )
        guard result.status == 0,
              let value = result.output.split(separator: "=", maxSplits: 1).last else {
            throw LocalSigningHarnessError.setup(result.output)
        }
        return value
            .filter { $0.isHexDigit }
            .uppercased()
    }

    private func runSetupSendingSIGQUITAfterTrust() throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [setupScript.path]
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let waiting = root.appendingPathComponent("trust-waiting")
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: waiting.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: waiting.path) else {
            process.terminate()
            process.waitUntilExit()
            throw LocalSigningHarnessError.setup("trust stage was not reached")
        }
        let signal = try run(
            executable: "/bin/kill",
            arguments: ["-s", "QUIT", String(process.processIdentifier)]
        )
        guard signal.status == 0 else {
            process.terminate()
            process.waitUntilExit()
            throw LocalSigningHarnessError.setup(signal.output)
        }
        try Data().write(to: root.appendingPathComponent("trust-release"))
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private enum LocalSigningFixtureProfile {
    case validLeaf
    case certificateAuthorityLeaf
    case expiredLeaf
}

private final class LocalBuildHarness {
    private static let identityName = "会议录音 Local Signing 2026-08-18"
    let root: URL
    let scratch: URL
    let appBundle: URL
    let keychain: URL
    let receiptDirectory: URL
    let receipt: URL
    var environment: [String: String]

    private let buildScript: URL

    init() throws {
        root = try Self.makeTemporaryDirectory()
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        appBundle = root.appendingPathComponent("会议录音-test.app", isDirectory: true)
        keychain = root.appendingPathComponent("build-test.keychain-db")
        receiptDirectory = root.appendingPathComponent("receipt", isDirectory: true)
        receipt = receiptDirectory.appendingPathComponent("local-signing-receipt-v1")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: receiptDirectory.path
        )
        let receiptContents = """
        version=1
        identity_name=\(Self.identityName)
        root_sha1=\(String(repeating: "C", count: 40))
        leaf_sha1=\(String(repeating: "A", count: 40))

        """
        try Data(receiptContents.utf8).write(to: receipt, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        let keychainPassword = UUID().uuidString
        let create = try Self.run(
            executable: "/usr/bin/security",
            arguments: ["create-keychain", "-p", keychainPassword, keychain.path]
        )
        guard create.status == 0 else { throw LocalSigningHarnessError.setup(create.output) }
        let unlock = try Self.run(
            executable: "/usr/bin/security",
            arguments: ["unlock-keychain", "-p", keychainPassword, keychain.path]
        )
        guard unlock.status == 0 else { throw LocalSigningHarnessError.setup(unlock.output) }

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        buildScript = projectURL.appendingPathComponent("scripts/build-app.sh")
        environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.deletingLastPathComponent().path + "/"
        environment["MEETING_RECORDER_BUILD_TESTING"] = "1"
        environment["MEETING_RECORDER_BUILD_TEST_ROOT"] = root.path
        environment["MEETING_RECORDER_BUILD_PATH"] = scratch.path
        environment["MEETING_RECORDER_APP_BUNDLE_PATH"] = appBundle.path
        environment["MEETING_RECORDER_BUILD_TEST_RECEIPT_PATH"] = receipt.path
    }

    func runBuild() throws -> (status: Int32, output: String) {
        try Self.run(
            executable: "/bin/bash",
            arguments: [buildScript.path],
            environment: environment
        )
    }

    func makeDuplicateIdentitySecurityTool(named name: String) throws -> URL {
        let tool = root.appendingPathComponent("duplicate-security")
        let firstHash = String(repeating: "A", count: 40)
        let secondHash = String(repeating: "B", count: 40)
        try Data("""
            #!/bin/bash
            printf '  1) %s "%s"\\n' '\(firstHash)' '\(name)'
            printf '  2) %s "%s"\\n' '\(secondHash)' '\(name)'
            printf '     2 valid identities found\\n'
            """.utf8).write(to: tool, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    func makeSingleIdentitySecurityTool(named name: String, fingerprint: String) throws -> URL {
        let tool = root.appendingPathComponent("single-security-\(fingerprint.prefix(8))")
        try Data("""
            #!/bin/bash
            printf '  1) %s "%s"\\n' '\(fingerprint)' '\(name)'
            printf '     1 valid identities found\\n'
            """.utf8).write(to: tool, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    func runProductionLayoutPreflightWithSymlinkedDist(
        outsideRoot: URL
    ) throws -> (status: Int32, output: String) {
        let project = root.appendingPathComponent("production-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: project.appendingPathComponent("dist").path,
            withDestinationPath: outsideRoot.path
        )
        var preflightEnvironment = environment
        preflightEnvironment["MEETING_RECORDER_BUILD_TEST_VALIDATE_PRODUCTION_DIST"] = "1"
        preflightEnvironment["MEETING_RECORDER_BUILD_TEST_PROJECT_DIR"] = project.path
        return try Self.run(
            executable: "/bin/bash",
            arguments: [buildScript.path],
            environment: preflightEnvironment
        )
    }

    func cleanup() {
        if FileManager.default.fileExists(atPath: keychain.path) {
            _ = try? Self.run(
                executable: "/usr/bin/security",
                arguments: ["delete-keychain", keychain.path]
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    static func makeTemporaryDirectory(
        named prefix: String = "meeting-recorder-build-test"
    ) throws -> URL {
        let result = try run(
            executable: "/usr/bin/mktemp",
            arguments: [
                "-d",
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(prefix).XXXXXX")
                    .path,
            ]
        )
        guard result.status == 0 else { throw LocalSigningHarnessError.setup(result.output) }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw LocalSigningHarnessError.setup("mktemp returned no path") }
        let canonicalPath = path.hasPrefix("/var/") ? "/private\(path)" : path
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private enum LocalSigningHarnessError: Error {
    case setup(String)
}

import Foundation
import XCTest

final class LocalSigningTests: XCTestCase {
    private static let identityName = "会议录音 Local Signing 2026-08-18"

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
        XCTAssertFalse(certificateText.output.contains("TLS Web Server Authentication"))
        XCTAssertFalse(certificateText.output.contains("E-mail Protection"))

        let validity = try harness.run(
            executable: "/usr/bin/openssl",
            arguments: ["x509", "-in", certificateURL.path, "-noout", "-checkend", "283824000"]
        )
        XCTAssertEqual(validity.status, 0, "The local identity must remain usable for at least nine years.")

        let leftoverNames = try FileManager.default.contentsOfDirectory(atPath: harness.root.path)
            .filter { $0.hasPrefix("meeting-recorder-signing-setup.") }
        XCTAssertTrue(leftoverNames.isEmpty, "Temporary PEM and PKCS#12 material must be removed on exit.")
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
    let root: URL
    let keychain: URL
    let securityLog: URL
    let trustRequestedFlag: URL
    var environment: [String: String] = [:]

    private let keychainPassword: String
    private let setupScript: URL

    init() throws {
        root = try Self.makeTemporaryDirectory()
        keychain = root.appendingPathComponent("test.keychain-db")
        securityLog = root.appendingPathComponent("security.log")
        trustRequestedFlag = root.appendingPathComponent("trust-requested")
        keychainPassword = UUID().uuidString

        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        setupScript = projectURL.appendingPathComponent("scripts/setup-local-signing.sh")
        let toolsURL = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsURL, withIntermediateDirectories: true)
        let securityTool = toolsURL.appendingPathComponent("security")
        try Self.writeExecutable(securityTool, source: """
            #!/bin/zsh
            set -euo pipefail
            log='\(securityLog.path)'
            trust_flag='\(trustRequestedFlag.path)'
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
                exit 0
            fi
            if [[ "${1:-}" == "find-identity" ]]; then
                filtered=()
                for argument in "$@"; do
                    [[ "$argument" == "-v" ]] || filtered+=("$argument")
                done
                exec /usr/bin/security "${filtered[@]}"
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
    }

    func runSetup() throws -> (status: Int32, output: String) {
        try run(
            executable: "/bin/bash",
            arguments: [setupScript.path],
            environment: environment
        )
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
        let certificateURL = root.appendingPathComponent("exported-certificate.pem")
        try Data(result.output.utf8).write(to: certificateURL, options: .atomic)
        return certificateURL
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

    private static func makeTemporaryDirectory() throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
        process.arguments = [
            "-d",
            FileManager.default.temporaryDirectory
                .appendingPathComponent("meeting-recorder-signing-test.XXXXXX")
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
}

private final class LocalBuildHarness {
    let root: URL
    let scratch: URL
    let appBundle: URL
    let keychain: URL
    var environment: [String: String]

    private let buildScript: URL

    init() throws {
        root = try Self.makeTemporaryDirectory()
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        appBundle = root.appendingPathComponent("会议录音-test.app", isDirectory: true)
        keychain = root.appendingPathComponent("build-test.keychain-db")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
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

    func cleanup() {
        if FileManager.default.fileExists(atPath: keychain.path) {
            _ = try? Self.run(
                executable: "/usr/bin/security",
                arguments: ["delete-keychain", keychain.path]
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let result = try run(
            executable: "/usr/bin/mktemp",
            arguments: [
                "-d",
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("meeting-recorder-build-test.XXXXXX")
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

import Foundation
import XCTest

final class BuildMetadataTests: XCTestCase {
    func testBundleMetadataDisablesUnsafeTerminationModes() throws {
        let script = try source("build.sh")
        XCTAssertFalse(script.contains("NSSupportsAutomaticTermination"))
        XCTAssertFalse(script.contains("NSSupportsSuddenTermination"))
    }

    func testPackageDeclaresEnglishLocalizationAndProcessesResources() throws {
        let package = try source("Package.swift")
        XCTAssertTrue(package.contains("defaultLocalization: \"en\""))
        XCTAssertTrue(package.contains(".process(\"Resources/en.lproj\")"))
        XCTAssertTrue(package.contains(".copy(\"Resources/Localizable.xcstrings\")"))
    }

    func testBundleBuildCopiesSwiftPMResourceBundle() throws {
        let script = try source("build.sh")
        XCTAssertTrue(script.contains("SysBar_SysBar.bundle"))
        XCTAssertTrue(script.contains("RESOURCE_BUNDLE_SRC"))
        XCTAssertTrue(script.contains("RESOURCE_BUNDLE_DEST"))
    }

    func testInstallDoesNotUseBroadPatternProcessTermination() throws {
        let script = try source("build.sh")
        XCTAssertFalse(script.contains("pkill -f"))
        XCTAssertTrue(script.contains("INSTALLED_EXECUTABLE"))
    }

    func testInstallerWaitsForTheValidatedInstalledProcessToExit() throws {
        let script = try source("build.sh")
        XCTAssertTrue(script.contains("wait_for_installed_exit"))
        XCTAssertTrue(script.contains("Installed SysBar did not exit"))
    }

    func testInstallerGuardsEmptyPIDArrayForSystemBash() throws {
        let script = try source("build.sh")

        XCTAssertTrue(script.contains("if (( ${#installed_pids[@]} > 0 )); then"))
    }

    func testSigningAvoidsDeprecatedDeepModeAndSupportsDeveloperIdentity() throws {
        let script = try source("build.sh")
        XCTAssertFalse(script.contains("codesign --force --deep"))
        XCTAssertTrue(script.contains("SYSBAR_SIGN_IDENTITY"))
    }

    func testReadmeStatesSwift6AndXcode16FloorInsteadOfStaleSwift510Floor() throws {
        let readme = try source("README.md")
        XCTAssertTrue(readme.contains("Swift 6.0+"))
        XCTAssertTrue(readme.contains("Xcode 16+"))
        XCTAssertFalse(readme.contains("Swift 5.10+"))
        XCTAssertFalse(readme.contains("Xcode 15.3+"))
    }

    func testBundleBuildFailsWithStatus3WhenTheExecutableOrBundleExceedsItsFixedByteBudget() throws {
        let script = try source("build.sh")
        XCTAssertNotNil(script.range(of: #"(?m)^EXECUTABLE_SIZE_BUDGET_BYTES=[0-9]+\s"#, options: .regularExpression))
        XCTAssertNotNil(script.range(of: #"(?m)^BUNDLE_SIZE_BUDGET_BYTES=[0-9]+\s"#, options: .regularExpression))
        XCTAssertTrue(script.contains("\"$EXECUTABLE_BYTES\" \"$EXECUTABLE_SIZE_BUDGET_BYTES\""))
        XCTAssertTrue(script.contains("\"$BUNDLE_BYTES\" \"$BUNDLE_SIZE_BUDGET_BYTES\""))
        XCTAssertTrue(script.contains("if (( actual_bytes > budget_bytes )); then"))
        XCTAssertTrue(script.contains("Size budget exceeded"))
        XCTAssertTrue(script.contains("exit 3"))
    }

    func testSizeBudgetMeasuresExactFileBytesRatherThanDiskBlocks() throws {
        let script = try source("build.sh")
        XCTAssertTrue(script.contains("/usr/bin/stat -f %z \"${MACOS_DIR}/${APP_NAME}\""))
        XCTAssertTrue(script.contains("/usr/bin/find \"$APP_PATH\" -type f -exec /usr/bin/stat -f %z {} +"))
        XCTAssertFalse(script.contains("du -h"))
        XCTAssertFalse(script.contains("du -sh"))
    }

    func testSizeBudgetIsCheckedOnTheSignedBundleBeforeAnythingIsInstalled() throws {
        let script = try source("build.sh")
        let verify = try XCTUnwrap(script.range(of: "codesign --verify --strict \"$APP_PATH\""))
        let measure = try XCTUnwrap(script.range(of: "EXECUTABLE_BYTES=\"$("))
        let failure = try XCTUnwrap(script.range(of: "exit 3"))
        let install = try XCTUnwrap(script.range(of: "if [[ \"${1:-}\" == \"--install\" ]]; then"))
        XCTAssertLessThan(verify.lowerBound, measure.lowerBound)
        XCTAssertLessThan(measure.lowerBound, failure.lowerBound)
        XCTAssertLessThan(failure.lowerBound, install.lowerBound)
    }

    func testReleaseBuildKeepsSizeOptimizationAndDeadStrippingFlags() throws {
        let package = try source("Package.swift")
        XCTAssertTrue(package.contains(".unsafeFlags([\"-Osize\"], .when(configuration: .release))"))
        XCTAssertTrue(package.contains("[\"-Xlinker\", \"-dead_strip\", \"-Xlinker\", \"-dead_strip_dylibs\"]"))
    }

    func testReadmeReleaseChecklistRepeatsThePerformancePassAgainstFixedTargets() throws {
        let readme = try source("README.md")
        XCTAssertTrue(readme.contains("## Release checklist"))
        XCTAssertTrue(readme.contains("EXECUTABLE_SIZE_BUDGET_BYTES"))
        XCTAssertTrue(readme.contains("at most 0.30 CPU-seconds"))
        XCTAssertTrue(readme.contains("under 45 MiB"))
    }

    func testSizeBudgetCheckStopsOverBudgetOrUnmeasurableBuildsAndPassesAtExactlyTheBudget() throws {
        let script = try source("build.sh")
        let verify = try XCTUnwrap(script.range(of: "codesign --verify --strict \"$APP_PATH\"\n"))
        let summary = try XCTUnwrap(
            script.range(of: "echo \"✓ Built ${APP_PATH}\"", range: verify.upperBound..<script.endIndex)
        )
        let sizeCheck = String(script[verify.upperBound..<summary.lowerBound])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SysBarBuildMetadataTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("SysBar.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: macOS.appendingPathComponent("SysBar"))
        try Data(count: 500).write(to: resources.appendingPathComponent("AppIcon.icns"))

        func runSizeCheck(
            executableBudget: Int,
            bundleBudget: Int,
            then extraCommands: String = ""
        ) throws -> (status: Int32, output: String, errors: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "set -euo pipefail\n\(sizeCheck)\(extraCommands)echo PAST_SIZE_CHECK\n"]
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "APP_NAME": "SysBar",
                "MACOS_DIR": macOS.path,
                "APP_PATH": app.path,
                "EXECUTABLE_SIZE_BUDGET_BYTES": String(executableBudget),
                "BUNDLE_SIZE_BUDGET_BYTES": String(bundleBudget)
            ]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: outputData, as: UTF8.self),
                String(decoding: errorData, as: UTF8.self)
            )
        }

        let atBudget = try runSizeCheck(executableBudget: 1_000, bundleBudget: 1_500)
        XCTAssertEqual(atBudget.status, 0)
        XCTAssertTrue(atBudget.output.contains("PAST_SIZE_CHECK"))
        XCTAssertFalse(atBudget.errors.contains("Size budget exceeded"))

        let executableOver = try runSizeCheck(executableBudget: 999, bundleBudget: 1_500)
        XCTAssertEqual(executableOver.status, 3)
        XCTAssertTrue(executableOver.errors.contains(
            "Size budget exceeded: executable \(macOS.path)/SysBar is 1000 bytes"
        ))
        XCTAssertTrue(executableOver.errors.contains("over its 999-byte"))
        XCTAssertTrue(executableOver.errors.contains("budget by 1 bytes."))
        XCTAssertFalse(executableOver.output.contains("PAST_SIZE_CHECK"))

        let bundleOver = try runSizeCheck(executableBudget: 1_000, bundleBudget: 1_499)
        XCTAssertEqual(bundleOver.status, 3)
        XCTAssertTrue(bundleOver.errors.contains("Size budget exceeded: app bundle \(app.path) is 1500 bytes"))
        XCTAssertFalse(bundleOver.output.contains("PAST_SIZE_CHECK"))

        let unmeasurable = try runSizeCheck(
            executableBudget: 1_000,
            bundleBudget: 1_500,
            then: "check_size_budget \"executable probe\" \"\" 1000\n"
        )
        XCTAssertEqual(unmeasurable.status, 1)
        XCTAssertTrue(unmeasurable.errors.contains("Could not measure the size of the executable probe"))
        XCTAssertFalse(unmeasurable.output.contains("PAST_SIZE_CHECK"))
    }

    func testReleaseBundleShipsAStrippedExecutableWithItsDSYMKeptOutsideTheApp() throws {
        let script = try source("build.sh")
        let strip = try XCTUnwrap(script.range(of: "strip \"${MACOS_DIR}/${APP_NAME}\""))
        let dsym = try XCTUnwrap(script.range(of: "dsymutil \"${MACOS_DIR}/${APP_NAME}\" -o \"${BUILD_DIR}/${APP_NAME}.app.dSYM\""))
        let sign = try XCTUnwrap(script.range(of: "codesign --verify --strict \"$APP_PATH\""))
        XCTAssertLessThan(dsym.lowerBound, strip.lowerBound, "debug info is saved before it is stripped")
        XCTAssertLessThan(strip.lowerBound, sign.lowerBound, "the signature covers the stripped executable")
    }

    func testTheTraceLanesNeverDrawWithASwiftUICanvasWhichRendersWithMetalInsideTheApp() throws {
        // A Canvas backdrop spiked the footprint by about 210 MB on every popover open.
        let trace = try source("Sources/SysBar/Trace.swift")
        XCTAssertFalse(trace.contains("Canvas {"))
        XCTAssertFalse(trace.contains(".drawingGroup("))
    }

    private func source(_ relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

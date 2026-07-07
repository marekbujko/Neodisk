import Testing
import Foundation
@testable import NeodiskKit

@Suite struct ScanExclusionMatcherTests {
    @Test func testMatcherHandlesManyExcludedChildren() {
        let rootPath = "/tmp/NeodiskProject"
        let matcher = ScanExclusionMatcher(
            patterns: [
                "node_modules/",
                "*.log",
                "Library/Caches/**"
            ],
            rootPath: rootPath,
            includeCloudStorage: false,
            cloudStorageRootPath: "\(rootPath)/Library/CloudStorage"
        )

        for index in 0..<512 {
            #expect(matcher.excludes(
                    URL(filePath: "\(rootPath)/Packages/pkg\(index)/node_modules", directoryHint: .isDirectory),
                    isDirectory: true
                ))
            #expect(matcher.excludes(
                    URL(filePath: "\(rootPath)/Logs/./debug-\(index).log"),
                    isDirectory: false
                ))
        }

        #expect(matcher.excludes(
                URL(filePath: "\(rootPath)/Library/Caches/build/artifact.o"),
                isDirectory: false
            ))
        #expect(matcher.excludes(
                URL(filePath: "\(rootPath)/Library/CloudStorage/Dropbox/remote.bin"),
                isDirectory: false
            ))
        #expect(!(matcher.excludes(
                URL(filePath: "\(rootPath)/Sources/App.swift"),
                isDirectory: false
            )))
    }
}

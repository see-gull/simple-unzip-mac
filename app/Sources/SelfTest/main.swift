import Foundation

// Entry point for the in-repo check suite.
//
// Command Line Tools on this machine ship neither XCTest nor swift-testing, so
// `swift test` is unavailable. Run these checks with:
//
//   swift run SelfTest
//
// Set ARCHIVE_TEST_BINARY to point at a specific 7zz build.

registerListingSuite()
registerTreeSuite()
registerParserSuite()
registerDecoderSuite()
registerToolSuite()
registerCommandSuite()
registerCancellationSuite()
registerIntegrationSuite()
registerTargetArchiveSuite()

let exitCode = await harness.run()
exit(exitCode)

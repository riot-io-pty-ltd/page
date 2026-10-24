// The rate-limit parser's tests now live in the SwiftPM test target:
//
//   swift test --filter 'ResetTextParsingTests|RateLimitRecordTests|LaunchDirectoryTests|RateLimitIndexTests|ResumeSchedulerTests'
//
// (Tests/ClaudePowerModeTests/RateLimitTests.swift and ResumeSchedulerTests.swift.)
// This file used to be a standalone script calling TranscriptParser, which
// can't compile outside the package; it's kept only as this pointer.
//
// Usage: swift Tools/TestParser.swift
import Foundation

print("""
TranscriptParser / RateLimitWatcher / ResumeScheduler tests live in the test target. Run:

  swift test --filter 'ResetTextParsingTests|RateLimitRecordTests|LaunchDirectoryTests|RateLimitIndexTests|ResumeSchedulerTests'
""")

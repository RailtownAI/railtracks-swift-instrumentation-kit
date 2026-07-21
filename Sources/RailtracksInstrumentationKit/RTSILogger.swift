//
//  RTSILogger.swift
//  RailtracksInstrumentationKit
//
//  Module-wide diagnostic logging via apple/swift-log.
//
//  Follows the Swift library log-level guidance:
//  https://www.swift.org/documentation/server/guides/libraries/log-levels.html
//  As a library we log mostly at `.trace` / `.debug`, and only escalate to
//  `.warning` when we silently drop or fail to parse data without re-throwing.
//
//  IMPORTANT: this library never calls `LoggingSystem.bootstrap` — that is the
//  consuming application's job. By default swift-log filters at `.info`, so all
//  `.trace` / `.debug` lines here stay silent until the app lowers the level.
//
//  The `RTSI` prefix (RailTracks Instrumentation) is distinct from the `RTS`
//  prefix used by the consuming RailtracksSwift library, so the enum and label
//  never collide.
//

import Logging

internal enum RTSILoggers {
    static let rtsiLogLabel = "railtracks.instrumentation.log"
    static let rtsiLog = Logger(label: RTSILoggers.rtsiLogLabel)
}

/// Module-wide logger. `internal` so it never collides with the host app's own
/// `log`. Use `log.trace/debug/warning(…)` anywhere in the module. swift-log
/// messages are `@autoclosure`, so string interpolation is not evaluated when
/// the active level filters the line out — per-event `.trace` calls cost ~zero
/// in production.
internal let log = RTSILoggers.rtsiLog

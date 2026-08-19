//  Log.swift
//
//  Everything the app wants to say about itself, at a level the user chooses.
//
//  This goes to the unified log rather than a file, so it lands next to the
//  driver's own os_log output and can be read with one predicate. The level is
//  a preference because the interesting failures here happen on someone else's
//  Mac, hours into a poll loop, and "turn on debug and send me the log" has to
//  be a thing you can ask for.

import Foundation
import os

enum LogLevel: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case debug = 0, info, warning, error
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .debug:   return "Debug"
        case .info:    return "Info"
        case .warning: return "Warning"
        case .error:   return "Error"
        }
    }

    var detail: String {
        switch self {
        case .debug:   return "Every poll, every record, every timing. Noisy on purpose."
        case .info:    return "State changes worth knowing about. The default."
        case .warning: return "Only things that went wrong but were survivable."
        case .error:   return "Only failures."
        }
    }

    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

enum Log {
    static let subsystem = "org.redrobo.ReDrobo"

    /// Mirrored out of Prefs rather than read from it, so logging from a
    /// background queue does not reach into an observable object.
    nonisolated(unsafe) static var level: LogLevel = .info

    private static let logger = Logger(subsystem: subsystem, category: "app")

    static func debug(_ message: @autoclosure () -> String) {
        guard level <= .debug else { return }
        // Evaluated first: os.Logger's interpolation is itself an autoclosure,
        // and nesting ours inside it makes the compiler treat it as escaping.
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String) {
        guard level <= .info else { return }
        // Evaluated first: os.Logger's interpolation is itself an autoclosure,
        // and nesting ours inside it makes the compiler treat it as escaping.
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    static func warning(_ message: @autoclosure () -> String) {
        guard level <= .warning else { return }
        // Evaluated first: os.Logger's interpolation is itself an autoclosure,
        // and nesting ours inside it makes the compiler treat it as escaping.
        let text = message()
        logger.warning("\(text, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }

    /// What to hand someone who asks how to see any of this. The driver logs
    /// under its own sender, so both are worth watching together.
    static let streamCommand =
        "log stream --predicate 'subsystem == \"org.redrobo.ReDrobo\" "
      + "|| sender == \"DroboDext\"' --level debug"

    static let showCommand =
        "log show --last 30m --predicate 'subsystem == \"org.redrobo.ReDrobo\" "
      + "|| sender == \"DroboDext\"' --info --debug"
}

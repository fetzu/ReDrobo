//  Redaction.swift
//
//  Taking identifying values back out of raw record bytes.
//
//  Split out of Diagnostics so it can be tested without dragging in AppKit and
//  the whole model — which matters, because the first version of this shipped a
//  report that said "names and serials removed" and then printed both.

import Foundation

enum Redaction {

    /// Blank every occurrence of every secret, wherever it appears.
    ///
    /// Blanking the fields ReDrobo decodes is not enough, and a live capture
    /// proved it: the enclosure name turned up inside FirmwareInfo, and five
    /// disk serials inside the stale tails of Options and Options2 — none of
    /// which are fields this app parses at all.
    static func scrub(_ data: Data, removing secrets: [Data]) -> Data {
        var copy = data
        for secret in secrets where secret.count >= minimumSecretLength {
            var from = copy.startIndex
            while from < copy.endIndex,
                  let found = copy[from...].firstRange(of: secret) {
                copy.replaceSubrange(found, with: Data(repeating: 0, count: found.count))
                from = found.upperBound
            }
        }
        return copy
    }

    /// Shorter needles than this match by accident and would punch holes in
    /// unrelated records.
    static let minimumSecretLength = 4

    static func secrets(from strings: [String]) -> [Data] {
        Set(strings)
            .filter { $0.count >= minimumSecretLength }
            .compactMap { $0.data(using: .utf8) }
    }

    /// How much of a record is safe to print.
    ///
    /// Anything past the declared length is stale buffer, and on a live 5D that
    /// stale buffer is the enclosure's own event log — capacities, serial
    /// numbers and slot numbers in plain text. Options and Options2 declare
    /// impossible lengths (2304 and 64513 for records of a few dozen bytes), so
    /// there the declared value bounds nothing and a hard cap is the only safe
    /// answer.
    static func printableLength(_ d: Data, redacted: Bool) -> Int {
        let declared = Int(d.count > 3 ? d.u16(2) : 0)
        let sane = declared > 0 && declared <= d.count - 4
        if sane { return min(4 + declared, d.count) }
        return redacted ? min(64, d.count) : d.count
    }
}


/// A classic hexdump: offset, sixteen bytes, ASCII gutter.
///
/// Written without String(format:) per byte because the Raw Records pane
/// rebuilds this for every record on every SwiftUI body evaluation, which is
/// every poll — thirteen records at up to 260 bytes was several thousand
/// format calls a time, on the main thread, to draw something that had not
/// changed.
enum Hex {
    private static let digits = Array("0123456789abcdef")

    static func dump(_ d: Data, limit: Int, indent: String = "") -> String {
        let end = min(max(limit, 0), d.count)
        guard end > 0 else { return indent + "(empty)" }

        var out = ""
        out.reserveCapacity(end / 16 * (indent.count + 78) + 80)
        var ascii = ""
        ascii.reserveCapacity(16)

        for i in 0..<end {
            if i % 16 == 0 {
                out += indent
                out.append(digits[(i >> 12) & 0xF])
                out.append(digits[(i >> 8) & 0xF])
                out.append(digits[(i >> 4) & 0xF])
                out.append(digits[i & 0xF])
                out += "  "
            }
            let b = d.u8(i)
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
            out.append(" ")
            ascii.append(b >= 0x20 && b < 0x7F ? Character(UnicodeScalar(b)) : ".")
            if i % 16 == 15 {
                out += " |" + ascii + "|\n"
                ascii.removeAll(keepingCapacity: true)
            }
        }
        if !ascii.isEmpty {
            out += String(repeating: "   ", count: 16 - ascii.count) + " |" + ascii + "|"
        } else if out.hasSuffix("\n") {
            out.removeLast()
        }
        return out
    }
}

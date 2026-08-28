//
//  LotFlight.swift
//  Indigo
//
//  thelotradio.com is a Next.js App Router site, so its data never arrives as
//  a document the way Kiosk's `__NEXT_DATA__` island does. It arrives as a
//  React Flight stream: newline-delimited rows, some carrying JSON, some
//  carrying a length-prefixed blob of text that the JSON refers to by row id.
//
//      1:{"items":[…,"description":"$22",…]}
//      22:T4fd,On this edition of NO DAWN we have resident threehz…
//
//  This reads that stream. It deliberately understands only two things —
//  where a row starts and how a JSON object nests — because the element trees
//  themselves are a rendering detail that changes with every redesign, while
//  the entries embedded in them are the site's actual content model.
//

import Foundation

nonisolated struct LotFlight: Sendable {
    /// The whole stream, rows and all, as bytes. Row lengths are counted in
    /// bytes rather than characters, and so is everything downstream.
    private let bytes: [UInt8]
    /// Length-prefixed text rows, keyed by row id. Long strings are hoisted
    /// out of the tree and referenced from it as "$22".
    private let texts: [String: String]
    /// JSON rows, keyed by row id, in the order they arrived.
    private let values: [(id: String, json: String)]

    // MARK: - Reading

    init(stream: String) {
        let bytes = Array(stream.utf8)
        var texts: [String: String] = [:]
        var values: [(id: String, json: String)] = []
        let count = bytes.count
        var index = 0

        while index < count {
            let idStart = index
            var cursor = index
            while cursor < count, Self.isRowIDByte(bytes[cursor]) { cursor += 1 }

            guard cursor > idStart, cursor < count, bytes[cursor] == UInt8(ascii: ":") else {
                // Not a row boundary — the stream was joined mid-row, or this
                // is a continuation line. Resync on the next newline.
                while index < count, bytes[index] != Self.newline { index += 1 }
                index += 1
                continue
            }

            let id = String(decoding: bytes[idStart..<cursor], as: UTF8.self)
            let payload = cursor + 1

            if payload < count, bytes[payload] == UInt8(ascii: "T") {
                var comma = payload + 1
                while comma < count, bytes[comma] != UInt8(ascii: ",") { comma += 1 }
                guard comma < count,
                      let length = Int(String(decoding: bytes[(payload + 1)..<comma], as: UTF8.self), radix: 16),
                      comma + 1 + length <= count
                else { break }
                let start = comma + 1
                texts[id] = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
                // A text row is followed immediately by the next row, with no
                // newline of its own.
                index = start + length
            } else {
                var end = payload
                while end < count, bytes[end] != Self.newline { end += 1 }
                values.append((id, String(decoding: bytes[payload..<end], as: UTF8.self)))
                index = end + 1
            }
        }

        self.bytes = bytes
        self.texts = texts
        self.values = values
    }

    /// Rebuilds the stream a server-rendered page ships inside its markup.
    /// Next.js emits it in slices as `self.__next_f.push([1,"…"])`, each slice
    /// a JavaScript string literal, and concatenating them gives the stream.
    static func page(html: String) -> LotFlight {
        let needle = "self.__next_f.push([1,"
        var joined = ""
        joined.reserveCapacity(html.utf8.count / 2)
        var search = html.startIndex

        while let marker = html.range(of: needle, range: search..<html.endIndex) {
            guard marker.upperBound < html.endIndex, html[marker.upperBound] == "\"" else {
                search = marker.upperBound
                continue
            }
            var cursor = html.index(after: marker.upperBound)
            var literalEnd: String.Index?
            while cursor < html.endIndex {
                let character = html[cursor]
                if character == "\\" {
                    cursor = html.index(cursor, offsetBy: 2, limitedBy: html.endIndex) ?? html.endIndex
                    continue
                }
                if character == "\"" {
                    literalEnd = cursor
                    break
                }
                cursor = html.index(after: cursor)
            }
            guard let literalEnd else { break }

            let literal = String(html[marker.upperBound...literalEnd])
            if let data = literal.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                joined += decoded
            }
            search = html.index(after: literalEnd)
        }
        return LotFlight(stream: joined)
    }

    // MARK: - Lookup

    /// The value a server action returned. Row 0 is the action's envelope and
    /// points at the row holding the result: `{"a":"$@1",…}`.
    var actionResult: Data? {
        let envelope = values.first { $0.id == "0" }?.json
        var target = "1"
        if let envelope,
           let object = try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any],
           let reference = object["a"] as? String,
           reference.hasPrefix("$@") {
            target = String(reference.dropFirst(2))
        }
        let json = values.first { $0.id == target }?.json ?? values.first { $0.id != "0" }?.json
        return json.map { Data($0.utf8) }
    }

    /// Every JSON object in the stream that carries `key` as one of its own
    /// fields, outermost first within each nesting.
    ///
    /// The site renders its entries into React element trees rather than into
    /// one addressable payload, so an episode is found by what it contains
    /// rather than by where it sits.
    func objects(containing key: String) -> [Data] {
        starts(ofObjectsContaining: key).compactMap { object(at: $0) }
    }

    /// The first such object. Most pages carry exactly one.
    func object(containing key: String) -> Data? {
        for start in starts(ofObjectsContaining: key) {
            if let object = object(at: start) { return object }
        }
        return nil
    }

    /// Resolves a `"$22"` placeholder to the text row it stands for. Anything
    /// that is not a reference is already the value.
    func resolve(_ value: String?) -> String? {
        guard let value else { return nil }
        guard value.hasPrefix("$"), value.count > 1 else { return value }
        let id = String(value.dropFirst())
        guard id.allSatisfy({ $0.isHexDigit }) else { return value }
        return texts[id]
    }

    // MARK: - Scanning

    private static let newline = UInt8(ascii: "\n")

    private static func isRowIDByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }

    /// One forward pass, tracking the brace stack, so the enclosing object of
    /// a key is known exactly. Walking backwards from the key would be shorter
    /// and wrong: a brace inside a show description is indistinguishable from
    /// structure unless the scan has seen where every string began.
    private func starts(ofObjectsContaining key: String) -> [Int] {
        let needle = Array(key.utf8)
        var found: [Int] = []
        var stack: [(offset: Int, isObject: Bool)] = []
        var index = 0
        let count = bytes.count

        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                var cursor = index + 1
                var escaped = false
                while cursor < count {
                    let inner = bytes[cursor]
                    if escaped { escaped = false }
                    else if inner == UInt8(ascii: "\\") { escaped = true }
                    else if inner == UInt8(ascii: "\"") { break }
                    cursor += 1
                }
                let isKey = cursor + 1 < count
                    && bytes[cursor + 1] == UInt8(ascii: ":")
                    && cursor - index - 1 == needle.count
                if isKey, Array(bytes[(index + 1)..<cursor]) == needle,
                   let owner = stack.last(where: { $0.isObject }) {
                    found.append(owner.offset)
                }
                index = cursor + 1
                continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                stack.append((index, byte == UInt8(ascii: "{")))
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                if !stack.isEmpty { stack.removeLast() }
            }
            index += 1
        }
        // The same object can hold the key twice only if the payload is
        // malformed, but de-duplicating keeps callers from parsing it twice.
        var seen = Set<Int>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The complete JSON object literal beginning at `start`.
    private func object(at start: Int) -> Data? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { return nil }
        var depth = 0
        var index = start
        let count = bytes.count

        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                var cursor = index + 1
                var escaped = false
                while cursor < count {
                    let inner = bytes[cursor]
                    if escaped { escaped = false }
                    else if inner == UInt8(ascii: "\\") { escaped = true }
                    else if inner == UInt8(ascii: "\"") { break }
                    cursor += 1
                }
                index = cursor + 1
                continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return Data(bytes[start...index]) }
            }
            index += 1
        }
        return nil
    }
}

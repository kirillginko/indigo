//
//  DigCache.swift
//  Indigo
//
//  Answers kept across navigation.
//
//  Two things made returning to a page feel like arriving at it for the first
//  time. The caches held one entry each, so opening anything else evicted what
//  you were about to come back to; and `revision` is a single counter for the
//  whole store, so writing a release invalidated the artist page as surely as
//  writing the artist would have.
//
//  Neither is worth solving precisely. Keeping several answers costs almost
//  nothing, and a stale answer shown instantly and corrected a moment later is
//  better than a loading bar in front of something the listener was reading
//  seconds ago.
//

import Foundation

struct DigCache<Value> {
    /// Enough for a session's worth of wandering. These are small structs; the
    /// limit is here so a long dig cannot grow without bound, not because the
    /// memory is precious.
    private let limit: Int
    private var entries: [String: (revision: Int, value: Value)] = [:]
    /// Least recently used first.
    private var order: [String] = []

    init(limit: Int = 24) {
        self.limit = limit
    }

    /// The answer, only if nothing has been written since it was worked out.
    func fresh(_ key: String, revision: Int) -> Value? {
        guard let entry = entries[key], entry.revision == revision else { return nil }
        return entry.value
    }

    /// The last answer, however old. For drawing a page immediately while the
    /// current one is worked out behind it.
    func any(_ key: String) -> Value? { entries[key]?.value }

    mutating func store(_ value: Value, key: String, revision: Int) {
        entries[key] = (revision, value)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

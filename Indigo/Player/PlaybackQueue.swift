//
//  PlaybackQueue.swift
//  Indigo
//
//  A flat list plus a cursor. Deliberately simple: no shuffle, no repeat, no
//  editing yet — those belong to a later milestone.
//

import Foundation

nonisolated struct PlaybackQueue: Sendable {
    private(set) var items: [MediaItem] = []
    private(set) var index: Int = 0

    var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var next: MediaItem? {
        items.indices.contains(index + 1) ? items[index + 1] : nil
    }

    var hasNext: Bool { items.indices.contains(index + 1) }
    var hasPrevious: Bool { items.indices.contains(index - 1) }

    var upNext: [MediaItem] {
        guard hasNext else { return [] }
        return Array(items[(index + 1)...])
    }

    var isEmpty: Bool { items.isEmpty }

    mutating func load(_ newItems: [MediaItem], startingAt start: Int) {
        items = newItems
        index = newItems.indices.contains(start) ? start : 0
    }

    /// Replaces the queue with a single item — used when switching to radio.
    mutating func loadSingle(_ item: MediaItem) {
        items = [item]
        index = 0
    }

    /// Swaps what sits under the cursor, for retrying the same recording by
    /// another route without disturbing the running order.
    mutating func replaceCurrent(with item: MediaItem) {
        guard items.indices.contains(index) else { return }
        items[index] = item
    }

    @discardableResult
    mutating func advance() -> MediaItem? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    @discardableResult
    mutating func rewind() -> MediaItem? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }

    mutating func moveCursor(to itemID: String) -> MediaItem? {
        guard let found = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        index = found
        return current
    }

    mutating func clear() {
        items = []
        index = 0
    }
}

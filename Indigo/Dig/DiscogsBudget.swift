//
//  DiscogsBudget.swift
//  Indigo
//
//  How many requests are left in this minute, according to Discogs.
//
//  Discogs allows sixty requests a minute and says where you are in that
//  window on every single response — `X-Discogs-Ratelimit`, `-Used` and
//  `-Remaining` — and none of it was being read. So the app discovered the
//  limit the only other way there is: by being refused. A trace of a real
//  session showed ninety-seven requests inside one minute, and the searches
//  at the end of it coming back in three milliseconds each, which is what a
//  429 looks like.
//
//  Being refused is not merely a wasted request. It is a wasted request that
//  arrives as an *answer*, and everything downstream then has to guess whether
//  it means "no such artist" or "not now". Reading the header instead means
//  the question is asked before the request rather than after it.
//
//  It also makes the split between work somebody is waiting for and work
//  nobody is worth stating in requests rather than in sleeps. The background
//  portrait fill is allowed to spend the budget down to a reserve and no
//  further; what is left belongs to the page in front of the listener.
//

import Foundation

nonisolated actor DiscogsBudget {
    static let shared = DiscogsBudget()

    /// Who is asking. Not a priority number — there are exactly two kinds of
    /// work here and they want opposite things from a shrinking budget.
    enum Work: Sendable {
        /// Somebody is looking at the thing this request is for.
        case foreground
        /// The backlog. Correct to abandon, always.
        case background
    }

    /// What the foreground keeps for itself.
    ///
    /// A cold artist page issues nine requests and a search issues three, so
    /// a dozen is about one of each with room to spare. Below this the
    /// backlog waits: it has all evening, and the page has a listener.
    static let reserve = 12

    /// Discogs' own numbers, from the last response that carried them.
    private var total = 60
    private var remaining = 60
    private var readAt: ContinuousClock.Instant?
    /// Requests sent since that reading, which Discogs has not counted for us
    /// yet. Several are usually in flight at once.
    private var issuedSinceRead = 0
    /// Set when Discogs actually refuses. Nothing is worth sending until it
    /// passes; the window is rolling, so part of the budget is back before
    /// the whole minute is up.
    private var refusedUntil: ContinuousClock.Instant?

    private static let window = Duration.seconds(60)
    private static let standDown = Duration.seconds(25)

    /// What is left, as far as anything here can tell.
    ///
    /// A reading more than a minute old describes a window that has since
    /// rolled, so it says nothing about this one — and assuming the worst
    /// there would leave the app permanently convinced it had no budget after
    /// any quiet spell.
    private var projected: Int {
        guard let readAt, ContinuousClock.now - readAt < Self.window else { return total }
        return max(0, remaining - issuedSinceRead)
    }

    /// Whether Discogs will take another request of this kind right now.
    func hasRoom(for work: Work) -> Bool {
        if let refusedUntil, ContinuousClock.now < refusedUntil { return false }
        return switch work {
        case .foreground: projected > 0
        case .background: projected > Self.reserve
        }
    }

    /// Counted before it is sent, not after it answers. Three searches leave
    /// at once and none of them has a header to report until all three are
    /// back; counting on the way out is what keeps the estimate honest in
    /// between.
    func willIssue() {
        issuedSinceRead += 1
    }

    /// What Discogs said about the budget on the way back.
    ///
    /// Only when it actually said something: the test transports answer
    /// without these headers, and treating their silence as a reading of zero
    /// would have the suite convinced it was rate-limited.
    ///
    /// The instant is a parameter so a test can take a reading that is already
    /// older than the window. Nothing else passes it.
    func record(_ response: HTTPURLResponse, at instant: ContinuousClock.Instant = .now) {
        guard let left = Self.header(response, "X-Discogs-Ratelimit-Remaining") else { return }
        remaining = left
        total = Self.header(response, "X-Discogs-Ratelimit") ?? total
        readAt = instant
        issuedSinceRead = 0
        refusedUntil = nil
    }

    /// Refused. Stand down, and say so to anything that asks.
    func recordRefusal() {
        remaining = 0
        readAt = .now
        issuedSinceRead = 0
        refusedUntil = ContinuousClock.now + Self.standDown
    }

    private static func header(_ response: HTTPURLResponse, _ name: String) -> Int? {
        (response.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespaces)).flatMap(Int.init)
    }
}

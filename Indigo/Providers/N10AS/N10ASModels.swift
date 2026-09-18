//
//  N10ASModels.swift
//  Indigo
//
//  Wire format for n10.as plus the shapes its pages render.
//
//  n10.as is a volunteer-run community station in Montréal — "world wide
//  wadio", broadcasting since 2016 from a room above Bar Système. Its site is
//  a React app with no server render, so nothing here is scraped: everything
//  comes from three JSON doors, and they disagree about what a broadcast is.
//
//  RadioCult runs the air — the stream, what is on it, and the calendar.
//  The station's own API carries the show directory. The recordings are on
//  Mixcloud, in one flat feed of 11,849 uploads going back to February 2016,
//  with no playlist per show and no link back to the directory.
//
//  So the idea running through this file is that a broadcast has to be read
//  out of its own title. That is where the show it belongs to lives, and the
//  night it went out, and often a guest — typed by hand every week for ten
//  years, which is exactly as consistent as that sounds.
//

import Foundation

// MARK: - Station directory wire types

/// A show as n10.as's own API publishes it.
///
/// This is the whole of what the station says about its programmes. It carries
/// no recordings and no broadcast history — `/uploads`, where that link would
/// be, needs a station login.
nonisolated struct N10ASShowDTO: Decodable, Sendable {
    let _id: String?
    let name: String?
    let slug: String?
    let description: String?
    /// Free text, as typed: "1st Sunday / 8PM EST / Quarterly".
    let timeslot: String?
    let image: String?
    /// The pre-2021 Cloudinary address, kept by the station as a fallback.
    let oldImage: String?
    let tags: [Tag]?
    let links: [Link]?

    nonisolated struct Tag: Decodable, Sendable {
        let label: String?
        let value: String?
    }

    /// The station leaves empty rows in the repeater rather than removing
    /// them, so a show with no links still has three of them.
    nonisolated struct Link: Decodable, Sendable {
        let name: String?
        let link: String?
    }
}

/// The station's Mixcloud account, read only for the size of its archive.
nonisolated struct MixcloudAccountDTO: Decodable, Sendable {
    let name: String?
    let city: String?
    let cloudcast_count: Int?
}

// MARK: - RadioCult wire types

/// RadioCult wraps everything in `{ success, result }` or `{ success, schedules }`.
nonisolated struct RadioCultLiveDTO: Decodable, Sendable {
    let success: Bool?
    let result: Result?

    nonisolated struct Result: Decodable, Sendable {
        /// "schedule" when a slot is running, something else when the station
        /// is filling. Only the content matters here.
        let status: String?
        let content: RadioCultSlotDTO?
        let metadata: Metadata?
    }

    /// What the playout is actually pushing. For n10.as this is "Live" during
    /// a live show and the name of the recording during a re-run, so it is
    /// never a track and never stands in for the show.
    nonisolated struct Metadata: Decodable, Sendable {
        let title: String?
        let artist: String?
        let album: String?
    }
}

nonisolated struct RadioCultScheduleDTO: Decodable, Sendable {
    let success: Bool?
    let schedules: [RadioCultSlotDTO]?
}

/// One slot on RadioCult's calendar. The UTC fields are the ones to trust —
/// `timezone` reads "America/Halifax" on every entry while the station is in
/// Montréal, so it is not used for anything.
nonisolated struct RadioCultSlotDTO: Decodable, Sendable {
    let id: String?
    let title: String?
    let description: String?
    let startDateUtc: String?
    let endDateUtc: String?
    let duration: Int?
    let media: Media?
    /// RadioCult's own colour for the slot, which the station does set.
    let color: String?

    nonisolated struct Media: Decodable, Sendable {
        /// "live" when somebody is in the room, "mix" when it is playing out
        /// a file.
        let type: String?
        let trackId: String?
    }

    var isLive: Bool { media?.type == "live" }
}

// MARK: - Domain types

nonisolated struct N10ASShow: Identifiable, Hashable, Sendable {
    let slug: String
    let title: String
    let summary: String?
    /// "1st Sunday / 8PM EST / Quarterly" — as the station typed it.
    let timeslot: String?
    let genres: [String]
    let imageURL: URL?
    let links: [MediaLink]

    var id: String { slug }

    var subtitle: String {
        [timeslot, genres.first]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

nonisolated struct N10ASEpisode: Identifiable, Hashable, Sendable {
    /// The Mixcloud slug. Every recording is on the station's own Mixcloud
    /// account, so the slug alone refetches it — which is what a crated
    /// broadcast opened months later from a cold start has.
    let id: String
    /// The title exactly as published, date and all.
    let title: String
    /// The programme the title names, before the guest and the date.
    let programme: String?
    /// Who was on, when the title says.
    let guest: String?
    let broadcastAt: Date?
    let duration: TimeInterval?
    let artworkURL: URL?
    /// The Mixcloud page, which is also what the widget loads.
    let permalink: URL
    let summary: String?
    let genres: [String]

    var mediaID: String { "n10as.episode.\(id)" }

    var broadcastLabel: String? {
        guard let broadcastAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: broadcastAt)
    }

    /// The title already carries its own date, so the line under it names the
    /// programme and whoever was guesting instead of repeating it.
    var listSubtitle: String {
        [programme, guest.map { "w/ \($0)" } ?? genres.first]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func mediaItem() -> MediaItem {
        MediaItem(
            id: mediaID,
            sourceID: N10ASProvider.providerID,
            kind: .episode,
            title: title,
            subtitle: programme ?? broadcastLabel,
            detail: "n10.as",
            genres: genres,
            remoteArtworkURL: artworkURL,
            playbackURL: permalink,
            duration: duration,
            embedProvider: .mixcloud
        )
    }
}

/// A slot on RadioCult's calendar.
nonisolated struct N10ASScheduleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let startsAt: Date
    let endsAt: Date
    /// Somebody in the room, as against a recording playing out.
    let isLive: Bool

    func contains(_ date: Date) -> Bool { startsAt <= date && date < endsAt }

    /// "18:00–20:00" in the listener's own time.
    var slot: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: startsAt))–\(formatter.string(from: endsAt))"
    }

    /// The station re-runs most of its week, and says so in the title:
    /// "Play Recent (2026-08-28) (Re-Run)".
    var isRerun: Bool { title.localizedCaseInsensitiveContains("(re-run)") }

    /// The title without the station's re-run bookkeeping, which is what a
    /// listener wants to read and what matches the directory.
    var cleanTitle: String { N10ASTitle.withoutRerunMarks(title) }

    func asRadioShow() -> RadioShow {
        RadioShow(
            title: cleanTitle,
            host: nil,
            summary: summary,
            location: "Montréal",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: nil
        )
    }
}

/// What RadioCult says is on the air this moment.
nonisolated struct N10ASOnAir: Hashable, Sendable {
    var showName: String?
    var showSummary: String?
    var startsAt: Date?
    var endsAt: Date?
    /// True when the slot is a live broadcast rather than a recording going
    /// out of the library.
    var isLiveSlot: Bool = false

    static let idle = N10ASOnAir()

    var isOnAir: Bool { showName != nil }

    var cleanName: String? { showName.map(N10ASTitle.withoutRerunMarks) }

    func asRadioShow() -> RadioShow? {
        guard let name = cleanName else { return nil }
        return RadioShow(
            title: name,
            host: nil,
            summary: showSummary,
            location: "Montréal",
            genres: [],
            moods: [],
            artworkURL: nil,
            startsAt: startsAt,
            endsAt: endsAt,
            detailID: nil
        )
    }
}

// MARK: - Mapping

extension N10ASShowDTO {
    func asShow() -> N10ASShow? {
        guard let identity = slug?.trimmingCharacters(in: .whitespaces), !identity.isEmpty
        else { return nil }
        let title = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        // The station moved its images off Cloudinary and kept the old address
        // beside the new one; a handful of shows only ever got the old one.
        let artwork = [image, oldImage]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            .compactMap { URL(string: $0) }
            .first

        return N10ASShow(
            slug: identity,
            title: title,
            summary: description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            timeslot: timeslot?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            genres: (tags ?? []).compactMap {
                ($0.label ?? $0.value)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            },
            imageURL: artwork,
            links: (links ?? []).compactMap { entry in
                guard let address = entry.link?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                      let url = URL(string: address), url.host != nil
                else { return nil }
                let label = HTMLText.decode(entry.name ?? "").trimmingCharacters(in: .whitespaces)
                return MediaLink(label: label.isEmpty ? MediaLink.label(for: url) : label, url: url)
            }
        )
    }
}

extension RadioCultSlotDTO {
    func asScheduleEntry() -> N10ASScheduleEntry? {
        let name = HTMLText.decode(title ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let start = N10ASTimestamp.parseISO(startDateUtc),
              let end = N10ASTimestamp.parseISO(endDateUtc),
              end > start
        else { return nil }

        return N10ASScheduleEntry(
            id: [id, startDateUtc].compactMap { $0 }.joined(separator: "|"),
            title: name,
            summary: description.flatMap(HTMLText.plainText)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            startsAt: start,
            endsAt: end,
            isLive: isLive
        )
    }
}

extension MixcloudCloudcastDTO {
    func asN10ASEpisode() -> N10ASEpisode? {
        let fromSlug = slug?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let fromKey = key.flatMap(N10ASEpisodeKey.slug(from:))
        guard let identity = fromSlug ?? fromKey else { return nil }
        let published = HTMLText.decode(name ?? "").trimmingCharacters(in: .whitespaces)
        guard !published.isEmpty, let address = url, let link = URL(string: address)
        else { return nil }

        let parsed = N10ASTitle.parse(published)

        return N10ASEpisode(
            id: identity,
            title: published,
            programme: parsed.programme,
            guest: parsed.guest,
            // The title's date is the night it went out; Mixcloud's upload
            // time is not. They agree within three days only seven times in
            // ten, and the tail runs to months — the station uploads in
            // batches. So the title wins and the upload time is the fallback.
            broadcastAt: parsed.date ?? N10ASTimestamp.parseISO(created_time),
            duration: audio_length.map(TimeInterval.init),
            artworkURL: artworkURL,
            permalink: link,
            summary: N10ASBlurb.showSpecific(description),
            genres: (tags ?? []).compactMap {
                $0.name.map(HTMLText.decode)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            }
        )
    }
}

// MARK: - Episode identity

nonisolated enum N10ASEpisodeKey {
    /// Mixcloud keys arrive as "/n10as/2026-09-17-exhalemp3/". Only the last
    /// component is kept: the account is always the station's.
    static func slug(from key: String) -> String? {
        key.split(separator: "/").last.map(String.init)?.nilIfEmpty
    }
}

// MARK: - Titles

/// Reading a broadcast out of its own title.
///
/// n10.as publishes "Maraschino Chalet w/ special guest bethytown 2026/09/17"
/// — the programme, sometimes a guest, then the night. Nothing else links a
/// recording to the show it belongs to, so this is load-bearing, and it is
/// parsing ten years of hand-typed titles rather than a format.
nonisolated enum N10ASTitle {
    struct Parsed: Equatable {
        var programme: String?
        var guest: String?
        var date: Date?
    }

    /// A trailing date in any of the orders the station has used. It has used
    /// all of them, sometimes in the same week, and sometimes with the
    /// separator doubled ("03/08//2023") or a stray "." or "/" on the end.
    private static let trailingDate = try? NSRegularExpression(
        pattern: #"[\s\-–,(\[]*(\d{1,4})[/.\-]{1,2}(\d{1,2})[/.\-]{1,2}(\d{2,4})[)\]]*[./]?\s*$"#
    )

    /// A date at the front instead, which a scattering of 2025–26 uploads use:
    /// "2026-03-04-Echoes of Time".
    private static let leadingDate = try? NSRegularExpression(
        pattern: #"^\s*(\d{4})[/.\-](\d{1,2})[/.\-](\d{1,2})[\s\-]*"#
    )

    /// How the station writes "with". Bare "w" is in here because the archive
    /// and the directory both use it — "Armable w Santinista", "Tender Grooves
    /// w silktits" — and without it the host stays stuck to the programme and
    /// the show never finds its own recordings.
    private static let guestSeparators = [
        " w/ ", " W/ ", " w\\ ", " w/. ", " w ", " W ",
        " with ", " With ", " WITH ",
        " feat. ", " feat ", " ft. ", " ft ", " hosted by ", " by "
    ]

    static func parse(_ title: String) -> Parsed {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mixcloud slugs end "mp3" and a few titles inherited it.
        if text.lowercased().hasSuffix(".mp3") { text = String(text.dropLast(4)) }

        var date: Date?
        (text, date) = strippingTrailingDate(text)
        if date == nil { (text, date) = strippingLeadingDate(text) }

        let (programme, guest) = splittingGuest(text)
        return Parsed(
            programme: programme?.nilIfEmpty,
            guest: guest?.nilIfEmpty,
            date: date
        )
    }

    /// The programme alone — what a show page matches on.
    static func programme(of title: String) -> String? { parse(title).programme }

    /// The one key a programme is matched on, from whichever side it arrives.
    ///
    /// The directory and the archive do not agree on what a show is called.
    /// The directory names a good few of them with their host — "Echo Chamber
    /// with Mole", "T Time with Tammy J", "Groovy time with Key Watch" —
    /// while the recordings are titled with the programme alone. Matching the
    /// two names as published left sixteen of the hundred and forty-seven
    /// shows unable to find a single one of their own broadcasts.
    ///
    /// So both sides are reduced the same way before they are compared:
    /// whatever a date and a host strip away is not part of the name. Across
    /// the current directory that reduction collides nothing — all 147 shows
    /// still key apart — and it lifts the shows that can reach their own
    /// recordings from 131 to 143.
    static func matchKey(_ name: String) -> String {
        RecordingKey.normalize(parse(withoutRerunMarks(name)).programme ?? name)
    }

    /// "Play Recent (2026-08-28) (Re-Run)" → "Play Recent". The station marks
    /// its re-runs in the calendar title, and the parenthesised date is the
    /// night being repeated, not the slot.
    static func withoutRerunMarks(_ title: String) -> String {
        var text = title
        for pattern in [#"\s*\(re-?run\)\s*"#, #"\s*\(\d{4}-\d{2}-\d{2}\)\s*"#] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Pieces

    private static func strippingTrailingDate(_ text: String) -> (String, Date?) {
        guard let expression = trailingDate else { return (text, nil) }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let head = Range(NSRange(location: 0, length: match.range.location), in: text)
        else { return (text, nil) }

        let numbers = (1...3).compactMap { index -> Int? in
            guard let part = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[part])
        }
        guard numbers.count == 3 else { return (text, nil) }
        let remainder = String(text[head]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (remainder.isEmpty ? text : remainder, date(from: numbers))
    }

    private static func strippingLeadingDate(_ text: String) -> (String, Date?) {
        guard let expression = leadingDate else { return (text, nil) }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let tail = Range(
                  NSRange(
                      location: match.range.upperBound,
                      length: range.length - match.range.upperBound
                  ),
                  in: text
              )
        else { return (text, nil) }

        let numbers = (1...3).compactMap { index -> Int? in
            guard let part = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[part])
        }
        guard numbers.count == 3 else { return (text, nil) }
        let remainder = String(text[tail]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (remainder.isEmpty ? text : remainder, date(from: [numbers[2], numbers[1], numbers[0]]))
    }

    /// Three numbers off the end of a title, in whichever order this one used.
    ///
    /// A four-digit first number is unambiguous, and so is any reading where
    /// one of the other two is above twelve. What is left — "12/05/2026" —
    /// genuinely cannot be resolved from the title, and is read day-first:
    /// across the archive the resolvable cases run 3,100 day-first to 22
    /// month-first, so day-first is right about 99% of the time and wrong in
    /// a way that shows a plausible date rather than none.
    private static func date(from numbers: [Int]) -> Date? {
        let (first, second, third) = (numbers[0], numbers[1], numbers[2])

        if first >= 1000 { return make(year: first, month: second, day: third) }

        let year = third >= 1000 ? third : 2000 + third
        if second > 12 { return make(year: year, month: first, day: second) }
        return make(year: year, month: second, day: first)
    }

    private static func make(year: Int, month: Int, day: Int) -> Date? {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        // The broadcast date is a calendar day in Montréal, not an instant.
        // Noon there keeps it on the right day everywhere it is displayed.
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .gmt
        guard let date = calendar.date(from: components) else { return nil }
        // A typo'd year can land in the future; "04/07/20265" is in the archive.
        return date > Date.now.addingTimeInterval(86_400 * 2) ? nil : date
    }

    /// Splits at the *earliest* separator in the title, not the first one in
    /// the list. "THE FRIEND HOUR WITH FRIENDS W/ BRAD DJ" has two, and taking
    /// them in list order made the programme "THE FRIEND HOUR WITH FRIENDS" —
    /// a name the directory has never heard of. The show is whatever comes
    /// before the first of them.
    private static func splittingGuest(_ text: String) -> (String?, String?) {
        let found = guestSeparators
            .compactMap { separator in text.range(of: separator).map { (separator, $0) } }
            .sorted { $0.1.lowerBound < $1.1.lowerBound }

        for (_, range) in found {
            let programme = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var guest = String(text[range.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|"))
            // "w/ special guest bethytown" — the words, not the name.
            for filler in ["special guest ", "special guests ", "guest ", "guests "] {
                if guest.lowercased().hasPrefix(filler) {
                    guest = String(guest.dropFirst(filler.count))
                }
            }
            // A separator at the very front is part of the name, not a split.
            guard !programme.isEmpty else { continue }
            return (programme, guest.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|")), nil)
    }
}

// MARK: - Helpers

nonisolated enum N10ASTimestamp {
    static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

/// Every upload carries the station's standing blurb — who n10.as are, the
/// donation link, the socials — appended to whatever the host wrote. Repeating
/// it on six thousand pages says nothing, and printing it under a broadcast
/// that has a real note of its own buries the note. So only the part above it
/// is kept, and a description that is nothing but the blurb becomes no
/// description at all.
nonisolated enum N10ASBlurb {
    /// Where the standing text begins. The station has reworded it over the
    /// years; these are the openings it has used.
    private static let markers = [
        "N10.AS (pronounced",
        "N10.AS is a",
        "n10.as is a",
        "N10.AS RADIO is",
        "Http://www.n10.as",
        "http://www.n10.as",
        "https://www.n10.as",
        "www.n10.as"
    ]

    static func showSpecific(_ description: String?) -> String? {
        guard let text = description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }

        var head = text
        for marker in markers {
            if let range = head.range(of: marker) {
                head = String(head[head.startIndex..<range.lowerBound])
            }
        }

        // Whatever survived may still end in the station's bare links.
        let kept = head
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return true }
                return !trimmed.lowercased().hasPrefix("http")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return kept.nilIfEmpty
    }
}

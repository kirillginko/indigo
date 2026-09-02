//
//  PanikHTML.swift
//  Indigo
//
//  Reading Radio Panik's pages.
//
//  This is the fragile part of the provider and it is kept in one file for
//  that reason: Panik publishes no catalogue API, so its directory, its week
//  and its track logs are read out of the markup its own site renders. If the
//  station redesigns, this is the file that breaks, and everything downstream
//  keeps its shape.
//
//  Each pattern below is written against a container the page uses to mean
//  something — `emission-resume` for a show card, `data-program-slug` for a
//  slot, `tracktime`/`trackartist`/`tracktitle` for a logged track — rather
//  than against layout, which is the part most likely to be restyled.
//

import Foundation

nonisolated enum PanikHTML {

    // MARK: - The shows directory

    /// `/emissions/` lists all hundred and twenty-odd shows in one page, with
    /// the picture, the heading and the blurb inline — so the directory costs
    /// one request rather than one per show.
    static func shows(in html: String) -> [PanikShow] {
        blocks(of: html, startingAt: "<div class=\"emission emission-resume").compactMap { block in
            guard let href = attribute("href", in: block),
                  let slug = slug(fromShowPath: href)
            else { return nil }

            let title = text(ofClass: "title", in: block, tag: "strong")
                .map(HTMLText.decode)?
                .trimmingCharacters(in: .whitespaces)
            guard let title, !title.isEmpty else { return nil }

            return PanikShow(
                slug: slug,
                title: title,
                summary: text(ofClass: "description", in: block, tag: "div")
                    .flatMap(HTMLText.plainText)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                imageURL: attribute("src", in: block).flatMap(absolute),
                categories: categories(in: block),
                links: [],
                slot: nil
            )
        }
    }

    /// The extra a show's own page carries over its listing entry: the fuller
    /// blurb, the big picture, when it goes out, and wherever else it lives.
    static func showDetail(in html: String, slug: String, listing: PanikShow?) -> PanikShow? {
        let title = meta(property: "og:title", in: html)
            ?? listing?.title
        guard let title, !title.isEmpty else { return listing }

        return PanikShow(
            slug: slug,
            title: title,
            summary: meta(property: "og:description", in: html)?.nilIfEmpty
                ?? listing?.summary,
            imageURL: meta(property: "og:image", in: html).flatMap(absolute)
                ?? listing?.imageURL,
            categories: categories(in: html).isEmpty
                ? (listing?.categories ?? [])
                : categories(in: html),
            links: links(in: html),
            slot: slot(in: html) ?? listing?.slot
        )
    }

    /// "Mardi 22:00", out of the element the page labels with it.
    ///
    /// Cut at the closing tag rather than taken as a fixed number of lines:
    /// the page happens to break the day and the hour onto separate lines, and
    /// counting on that swallowed whatever element came next the moment it
    /// did not.
    private static func slot(in html: String) -> String? {
        guard let block = blocks(
            of: html, startingAt: "<span class=\"label\">", endingAt: "</span>"
        ).first else { return nil }

        let words = HTMLText.plainText(block)?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let words, !words.isEmpty else { return nil }
        return words.joined(separator: " ").nilIfEmpty
    }

    /// Where else the show lives — its Mixcloud, its Instagram. The station's
    /// own addresses are not links off the page, so they are dropped.
    private static func links(in html: String) -> [MediaLink] {
        // One chip a destination. A page links its Mixcloud three times over —
        // header, body, footer — and often as both http and https, so the host
        // is what counts as the same place, not the exact address.
        var seen = Set<String>()
        return matches(#"href="(https?://[^"]+)""#, in: html)
            .compactMap { address -> MediaLink? in
                guard let url = URL(string: address), let host = url.host?.lowercased()
                else { return nil }
                guard !host.contains("radiopanik.org"), !host.contains("domainepublic.net")
                else { return nil }
                guard seen.insert(host.replacingOccurrences(of: "www.", with: "")).inserted
                else { return nil }
                return MediaLink(label: MediaLink.label(for: url), url: url)
            }
    }

    // MARK: - The week

    /// `/programme/` renders a week as seven containers, each named for the
    /// day it holds — "Program-week-2026-08-31-043000". The suffix is the hour
    /// Panik's broadcast day begins, which is why a slot at 00:00 sits at the
    /// bottom of the previous day's list and belongs to the next date.
    static func schedule(in html: String, zone: TimeZone) -> [PanikScheduleEntry] {
        var entries: [PanikScheduleEntry] = []
        let days = dayContainers(in: html)

        for (date, container) in days {
            for block in blocks(of: container, startingAt: "<li class=", endingAt: "</li>") {
                guard block.contains("data-program-slug") else { continue }
                guard let time = text(ofClass: "programDate", in: block, tag: "div")
                    .flatMap({ HTMLText.plainText($0) })?
                    .trimmingCharacters(in: .whitespaces)
                else { continue }
                guard let startsAt = moment(date: date, clock: time, zone: zone) else { continue }

                let slug = attribute("data-program-slug", in: block)
                guard let title = heading(in: block) else { continue }

                entries.append(
                    PanikScheduleEntry(
                        id: "\(slug ?? title)|\(startsAt.timeIntervalSince1970)",
                        title: title,
                        showSlug: slug,
                        categories: categories(in: block),
                        startsAt: startsAt,
                        playlistPath: matches(#"href="(/emissions/[^"]*/playlist/[^"]*)""#, in: block).first
                    )
                )
            }
        }

        // Panik publishes a start per slot and no end, so each runs until the
        // next begins. Sorting first is what makes that true across the day
        // boundary as well as within a day.
        entries.sort { $0.startsAt < $1.startsAt }
        for index in entries.indices.dropLast() {
            entries[index].endsAt = entries[index + 1].startsAt
        }
        return entries
    }

    /// Each day's container and the date in its class name.
    private static func dayContainers(in html: String) -> [(Date, String)] {
        let pattern = #"Program-week-(\d{4})-(\d{2})-(\d{2})-\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let found = regex.matches(in: html, range: range)

        var days: [(Date, String)] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels") ?? .current

        for (offset, match) in found.enumerated() {
            guard let year = intGroup(match, 1, in: html),
                  let month = intGroup(match, 2, in: html),
                  let day = intGroup(match, 3, in: html),
                  let date = calendar.date(
                      from: DateComponents(year: year, month: month, day: day)
                  )
            else { continue }

            // The container runs to wherever the next one starts. The class is
            // named twice per day — once on the tab, once on the panel — so
            // the slots are simply whatever falls between two names.
            guard let start = Range(match.range, in: html) else { continue }
            let end = offset + 1 < found.count
                ? Range(found[offset + 1].range, in: html)?.lowerBound ?? html.endIndex
                : html.endIndex
            guard start.upperBound < end else { continue }
            days.append((date, String(html[start.upperBound..<end])))
        }
        return days
    }

    /// A wall-clock time on a broadcast day. Panik's day starts at 04:30, so
    /// anything earlier than that belongs to the following date — which is how
    /// a slot at 00:00 ends up listed under the evening before.
    private static func moment(date: Date, clock: String, zone: TimeZone) -> Date? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = parts[0]
        components.minute = parts[1]
        guard let moment = calendar.date(from: components) else { return nil }
        let startOfBroadcastDay = 4 * 60 + 30
        guard parts[0] * 60 + parts[1] < startOfBroadcastDay else { return moment }
        return calendar.date(byAdding: .day, value: 1, to: moment)
    }

    // MARK: - Track logs

    /// A day's log on one of the continuous-music shows: the minute, the
    /// artist and the title, each in its own element — which is why these can
    /// become real recordings rather than a line of text to squint at.
    static func tracks(in html: String) -> [PanikTrack] {
        let times = matches(#"<span class="tracktime">([^<]*)</span>"#, in: html)
        let artists = matches(#"<span class="trackartist">([^<]*)</span>"#, in: html)
        let titles = matches(#"<span class="tracktitle">([^<]*)</span>"#, in: html)

        // The three run in lockstep down the page; anything short of a full
        // row is a page that did not render the way this expects.
        guard titles.count == artists.count, titles.count == times.count else { return [] }

        return titles.indices.compactMap { index in
            let title = HTMLText.decode(titles[index]).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return PanikTrack(
                index: index,
                time: times[index].trimmingCharacters(in: .whitespaces).nilIfEmpty,
                artist: HTMLText.decode(artists[index])
                    .trimmingCharacters(in: .whitespaces).nilIfEmpty,
                title: title
            )
        }
    }

    // MARK: - Reading bits of markup

    /// "/emissions/afrozik/" → "afrozik". Anything deeper is an episode, and
    /// anything else is not a show.
    static func slug(fromShowPath path: String) -> String? {
        let trimmed = path.split(separator: "?").first.map(String.init) ?? path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, parts[0] == "emissions" else { return nil }
        return parts[1]
    }

    static func absolute(_ path: String) -> URL? {
        if path.hasPrefix("http") { return URL(string: path) }
        guard path.hasPrefix("/") else { return nil }
        return URL(string: "https://www.radiopanik.org" + path)
    }

    private static func categories(in html: String) -> [String] {
        var seen = Set<String>()
        return matches(#"<span class="[^"]*category">([^<]*)</span>"#, in: html)
            .map { HTMLText.decode($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func meta(property: String, in html: String) -> String? {
        let patterns = [
            #"<meta[^>]*property="\#(property)"[^>]*content="([^"]*)""#,
            #"<meta[^>]*content="([^"]*)"[^>]*property="\#(property)""#,
            #"<meta[^>]*name="\#(property)"[^>]*content="([^"]*)""#
        ]
        for pattern in patterns {
            if let found = matches(pattern, in: html).first {
                return HTMLText.decode(found).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func attribute(_ name: String, in block: String) -> String? {
        matches("\(name)=\"([^\"]*)\"", in: block).first
    }

    private static func text(ofClass name: String, in block: String, tag: String) -> String? {
        matches("<\(tag) class=\"[^\"]*\(name)[^\"]*\">(.*?)</\(tag)>", in: block, dotAll: true)
            .first
    }

    /// What a slot is called.
    ///
    /// The cell holds one of three things depending on what is scheduled: a
    /// show card with a `<strong>` heading, a specific episode nested under
    /// `<div class="title">`, or a bare link for the continuous-music hours.
    /// Each is tried in turn and the answer is stripped of markup either way,
    /// so a heading that arrives wrapped in an anchor does not reach the
    /// screen as one.
    private static func heading(in block: String) -> String? {
        let candidates = [
            text(ofClass: "title", in: block, tag: "strong"),
            text(ofClass: "title", in: block, tag: "div"),
            matches("<em>(.*?)</em>", in: block, dotAll: true).first,
            matches("<a[^>]*>(.*?)</a>", in: block, dotAll: true).first
        ]
        for candidate in candidates.compactMap({ $0 }) {
            guard let text = HTMLText.plainText(candidate)?
                .components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
            else { continue }
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Every capture of the first group, in order.
    private static func matches(
        _ pattern: String,
        in text: String,
        dotAll: Bool = false
    ) -> [String] {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[captured])
        }
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return Int(text[range])
    }

    /// Splits a document on a repeated opening marker, cutting each block at
    /// `endingAt` when one is given.
    ///
    /// The cut matters more than it looks: without it a block runs on into the
    /// next entry, and a slot with no heading of its own quietly adopts the
    /// heading of the one below it — which is a wrong answer that looks like a
    /// right one.
    private static func blocks(
        of html: String,
        startingAt marker: String,
        endingAt terminator: String? = nil
    ) -> [String] {
        let parts = html.components(separatedBy: marker)
        guard parts.count > 1 else { return [] }
        return parts.dropFirst().map { part in
            guard let terminator, let end = part.range(of: terminator) else {
                return String(part.prefix(6000))
            }
            return String(part[part.startIndex..<end.lowerBound])
        }
    }

}

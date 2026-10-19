//
//  ContributorRole.swift
//  Indigo
//
//  What somebody did on a record, and so what a connection through it is
//  worth: the one taxonomy For You, DIG and Hear next sort credits by.
//
//  Discogs credits everyone who worked on a record -- the drummer, the
//  producer, the engineer who mixed it, the house that cut the lacquer and the
//  person who took the photograph -- and every one of those credits is true.
//  Only some of them are a reason to listen to somebody. A walk that treats
//  them alike sends a listener from a jazz record through its mastering
//  engineer into a page of other people's masters, and For You recommended
//  mix engineers that way.
//
//  Three classes, strongest first:
//
//  - **Musical** -- the people who made the music: main and featured artists,
//    singers, players (session players too), band members, conductors,
//    composers, songwriters, lyricists and arrangers, and anybody a record
//    names as an artist beside another ("Credited together").
//  - **Creative** -- the people who shaped the record as music: producers and
//    co-producers, beatmakers and programmers, remixers and re-editors, DJs
//    and their mixes. In electronic music and hip-hop the producer often
//    made the record, so a producer is never technical.
//  - **Technical** -- the people who worked the equipment or the object:
//    recording, mixing and mastering engineers, lacquer cutters, editors,
//    transfer and restoration, tape ops and technicians; and the credits
//    about the sleeve and the business rather than the sound -- artwork,
//    design, photography, liner notes, executive production, A&R,
//    management, compilation.
//
//  It is the *relationship* that is classified, never the person. Somebody
//  who mixed one record and played bass on another is reached as a bassist
//  through the second; somebody who only ever mixed a listener's records is
//  not a recommendation, however good a musician they are elsewhere, because
//  nothing the listener keeps says so. The credit itself stays: it is drawn
//  on the release page and kept in the graph, and only stops being a route.
//
//  Read from the role as Discogs states it, by whole words and the
//  qualifiers in brackets, not by a list of every instrument: an allowlist
//  of musical roles would have to name the thousands Discogs has and would
//  quietly drop the interesting ones. So "musical" is what is left once the
//  creative and technical jobs are recognised -- the small closed sets.
//

import Foundation

nonisolated enum ContributorRole: String, Hashable, Sendable, CaseIterable {
    case musical
    case creative
    case technical

    /// Strongest first: a bassist who also engineered is a bassist.
    var rank: Int {
        switch self {
        case .musical: 0
        case .creative: 1
        case .technical: 2
        }
    }

    /// Whether a connection of this kind is a reason to go to somebody.
    var leadsToSomebody: Bool { self != .technical }

    // MARK: A credit

    /// What a credited role was, or nil when there is no role to read. A
    /// role naming several jobs -- Discogs writes "Producer, Mixed By" in one
    /// field -- is the strongest of them.
    static func of(credit role: String?) -> ContributorRole? {
        guard let role else { return nil }
        var best: ContributorRole?
        for job in jobs(in: role) {
            let found = of(job: job)
            if best == nil || found.rank < (best?.rank ?? .max) { best = found }
        }
        return best
    }

    /// One job: its words, and the words of its bracketed qualifier.
    ///
    /// The qualifier decides first where it says so -- "Programmed By
    /// [Technical]" is a technician, "Mixed By [DJ Mix]" a DJ -- and the job
    /// otherwise.
    static func of(job: Job) -> ContributorRole {
        if job.qualifier.contains("technical") { return .technical }
        let words = job.words
        let all = words + job.qualifier
        func has(_ word: String) -> Bool { words.contains(word) }
        func starts(_ prefix: String) -> Bool { words.contains { $0.hasPrefix(prefix) } }
        // A sound designer makes sounds; any other designer made the sleeve.
        let soundDesign = has("sound") && starts("design")

        // The business and the object, before production: an executive
        // producer ran the budget, not the session.
        if words.contains(where: { administrative.contains($0) }) || starts("supervis") || starts("coordinat")
            || all.contains("executive") || (has("a") && has("r")) || (!soundDesign && phrase(words, presentationPhrases)) {
            return .technical
        }
        // Remixes, edits and DJ mixes are music made out of music.
        if starts("remix") || has("reedit") || (has("re") && (has("edit") || has("edited")))
            || all.contains("dj") || starts("turntabl") {
            return .creative
        }
        if starts("produc") || starts("coproduc") || starts("beat") || starts("programm") || has("sampler")
            || soundDesign {
            return .creative
        }
        // "Field Recording" is the sound a record is made of, not the act of
        // capturing somebody else's.
        if has("field") && starts("record") { return .musical }
        if words.contains(where: { word in technicalStems.contains { word.hasPrefix($0) } })
            || has("mix") || has("mixed") || has("mixing") || has("mixer") || has("edit") || has("edited")
            || has("editor") || has("editing") || (has("cut") && has("by")) || has("dmm") || (has("tape") && has("op")) {
            return .technical
        }
        return .musical
    }

    /// The words that make a job technical wherever they appear: engineer,
    /// mastered, remastered, recorded, lacquer, transferred, restored...
    private static let technicalStems = [
        "engineer", "mastered", "mastering", "premaster", "remaster", "recorded", "recording", "recordist",
        "lacquer", "transfer", "restor", "technician", "tracked", "overdubbed",
    ]

    /// Credits about the business or the paperwork.
    private static let administrative: Set<String> = [
        "management", "manager", "legal", "booking", "compiled", "compiler", "compilation", "copyright",
        "phonographic", "publisher", "published", "licensed", "distributed", "manufactured", "pressed",
        "marketing", "promotion", "translation", "translated", "sponsor", "funding", "thanks",
        "interview", "interviewer", "interviewed", "transcription", "research", "researcher",
    ]

    /// Credits about the sleeve, the pictures and the words around the music.
    private static let presentationPhrases: [[String]] = [
        ["design"], ["designed"], ["designer"], ["artwork"], ["art", "direction"], ["art", "director"], ["art", "by"],
        ["photography"], ["photographer"], ["photo"], ["photos"], ["illustration"], ["illustrated"], ["layout"],
        ["sleeve"], ["cover"], ["liner", "notes"], ["notes"], ["typography"], ["lettering"], ["painting"],
        ["video"], ["film"], ["filmed"], ["director"], ["styling"], ["stylist"], ["model"], ["concept"],
        ["graphics"], ["graphic"], ["calligraphy"], ["logo"], ["make", "up"], ["hair"], ["lighting"],
    ]

    /// Whether every word of any of these phrases is among the job's words.
    /// "Director" alone is the video's; "Musical Director" is a conductor.
    private static func phrase(_ words: [String], _ phrases: [[String]]) -> Bool {
        if words.contains("musical") || words.contains("music") { return false }
        return phrases.contains { $0.allSatisfy(words.contains) }
    }

    /// A job as Discogs writes it, split into lowercase words, with its
    /// bracketed qualifier apart: "Engineer [Assistant]" is the words
    /// ["engineer"] and the qualifier ["assistant"].
    nonisolated struct Job: Equatable, Sendable {
        let words: [String]
        let qualifier: [String]
    }

    /// The jobs in a role field: split on commas outside brackets.
    static func jobs(in role: String) -> [Job] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in role {
            switch character {
            case "[": depth += 1; current.append(character)
            case "]": depth = max(0, depth - 1); current.append(character)
            case "," where depth == 0: parts.append(current); current = ""
            default: current.append(character)
            }
        }
        parts.append(current)
        return parts.compactMap { part in
            let lowered = part.lowercased()
            var main = lowered
            var qualifier = ""
            if let open = lowered.firstIndex(of: "[") {
                main = String(lowered[..<open])
                let close = lowered[open...].firstIndex(of: "]") ?? lowered.endIndex
                qualifier = String(lowered[lowered.index(after: open)..<close])
            }
            let words = Self.words(main)
            guard !words.isEmpty else { return nil }
            return Job(words: words, qualifier: Self.words(qualifier))
        }
    }

    /// Lowercase words, hyphens and punctuation as spaces, "&" kept as "a r"
    /// for A&R, "re-edit" and "reedit" as one word.
    private static func words(_ text: String) -> [String] {
        let folded = text.replacingOccurrences(of: "re-edit", with: "reedit")
            .replacingOccurrences(of: "co-produc", with: "coproduc")
        return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: A relationship

    /// What a connection between two people rests on, or nil when it is not
    /// a connection through a record's credits at all -- a label, a radio
    /// show, a shared style. Those are judged on their own terms elsewhere.
    ///
    /// A credit edge states the job ("Mastered By on Pool"); one that does
    /// not -- "Credited together", "Made Pool together", "Appears on Pool" --
    /// names both as the record's artists, which is a musical fact. A band
    /// somebody is in is musical too.
    static func of(edge: MusicEdge) -> ContributorRole? {
        switch edge.kind {
        case .producer, .personnel, .collaborator, .sameRelease:
            if let role = DigRecommender.role(in: edge.reason), let found = of(credit: role) { return found }
            return edge.kind == .producer ? .creative : .musical
        case .aliasOrProject:
            return .musical
        default:
            return nil
        }
    }

    /// Whether an edge may carry a recommendation of the person it reaches:
    /// everything but a purely technical credit.
    static func canRecommend(_ edge: MusicEdge) -> Bool {
        of(edge: edge)?.leadsToSomebody ?? true
    }
}

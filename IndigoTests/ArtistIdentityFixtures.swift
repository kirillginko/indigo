//
//  ArtistIdentityFixtures.swift
//  IndigoTests
//
//  Discogs artist entries as `artists/{id}` returned them on 2026-10-09, cut to
//  the fields identity reads. Real data on purpose: whether "Prefuse73" is
//  Prefuse 73, and whether Micachu is Mica Levi, is a claim Discogs makes, and
//  the tests should rest on what it actually says.
//

import Foundation
@testable import Indigo

enum ArtistIdentityFixtures {
    /// Raw entries, by Discogs id.
    static let entries: [Int: String] = [
        // Prefuse 73
        3722: #"{"id": 3722, "name": "Prefuse 73", "realname": "Guillermo Scott Herren", "profile": "Music producer, who has been based in Atlanta, Barcelona and", "namevariations": ["Pre fuse 73", "Pre-Fuse 73", "Pre-fuse73", "Prefuse", "Prefuse 73 & The Failing Institute Of...", "Prefuse-73", "Prefuse/73", "Prefuse73", "Prefuze 73"], "aliases": [{"id": 1918, "name": "Delarosa & Asora"}, {"id": 104331, "name": "Ahmad Szabo"}, {"id": 227795, "name": "Piano Overlord"}, {"id": 229415, "name": "Scott Herren"}, {"id": 1580833, "name": "The Predicate Production Guild"}, {"id": 6810891, "name": "Reto A Ichi"}], "images": [{"type": "primary"}]}"#,
        // Piano Overlord
        227795: #"{"id": 227795, "name": "Piano Overlord", "realname": "Guillermo Scott Herren", "aliases": [{"id": 1918, "name": "Delarosa & Asora"}, {"id": 3722, "name": "Prefuse 73"}, {"id": 104331, "name": "Ahmad Szabo"}, {"id": 229415, "name": "Scott Herren"}, {"id": 1580833, "name": "The Predicate Production Guild"}, {"id": 6810891, "name": "Reto A Ichi"}], "images": [{"type": "primary"}]}"#,
        // Scott Herren
        229415: #"{"id": 229415, "name": "Scott Herren", "realname": "Guillermo Scott Herren", "profile": "Born: 1976, Atlanta, Georgia", "namevariations": ["GSH", "Guillermo", "Guillermo Herren", "Guillermo S Herren", "Guillermo S. Herren", "Guillermo Scott Herren", "Guillermo Scott-Herren", "Herren", "S. Herren", "S.Herren", "Scott", "Scott Heren", "Scott Herron"], "aliases": [{"id": 1918, "name": "Delarosa & Asora"}, {"id": 3722, "name": "Prefuse 73"}, {"id": 104331, "name": "Ahmad Szabo"}, {"id": 227795, "name": "Piano Overlord"}, {"id": 1580833, "name": "The Predicate Production Guild"}, {"id": 6810891, "name": "Reto A Ichi"}], "groups": [{"id": 2198, "name": "Communication Project"}, {"id": 3838, "name": "Savath & Savalas"}, {"id": 670838, "name": "A Cloud Mireya"}, {"id": 1470236, "name": "Diamond Watch Wrists"}, {"id": 1499550, "name": "Risil"}, {"id": 3452158, "name": "Sons Of The Morning"}, {"id": 5267997, "name": "Fudge (22)"}], "images": [{"type": "primary"}]}"#,
        // Micachu
        1172814: #"{"id": 1172814, "name": "Micachu", "realname": "Mica Levi", "profile": "British musician and recording artist.\r\nBased in London, pla", "aliases": [{"id": 2576890, "name": "Mica Levi"}, {"id": 9565285, "name": "Meeks (7)"}], "images": [{"type": "primary"}]}"#,
        // The Predicate Production Guild
        1580833: #"{"id": 1580833, "name": "The Predicate Production Guild", "namevariations": ["The Predicate"], "aliases": [{"id": 1918, "name": "Delarosa & Asora"}, {"id": 3722, "name": "Prefuse 73"}, {"id": 104331, "name": "Ahmad Szabo"}, {"id": 227795, "name": "Piano Overlord"}, {"id": 229415, "name": "Scott Herren"}, {"id": 6810891, "name": "Reto A Ichi"}], "images": [{"type": "primary"}]}"#,
        // Anika (9)
        1982320: #"{"id": 1982320, "name": "Anika (9)", "realname": "Annika Henderson", "profile": "Performing alias of British-German singer-songwriter and pol", "aliases": [{"id": 3999072, "name": "Annika Henderson"}], "images": [{"type": "primary"}]}"#,
        // Mica Levi
        2576890: #"{"id": 2576890, "name": "Mica Levi", "realname": "Micaela Levi", "profile": "Mica Levi is a classically trained musician, composer, perfo", "namevariations": ["Blue Shit", "M. Levi", "Meeks", "Mica", "Micaela Rachel Levi", "Michaela Levi"], "aliases": [{"id": 1172814, "name": "Micachu"}, {"id": 9565285, "name": "Meeks (7)"}], "groups": [{"id": 1874692, "name": "Kwesachu"}, {"id": 2071978, "name": "M.A.T.H.E.S."}, {"id": 6614905, "name": "Curl (9)"}, {"id": 8207804, "name": "Good Sad Happy Bad"}, {"id": 8234107, "name": "Micachu & The Shapes"}], "images": [{"type": "primary"}]}"#,
        // Annika Henderson
        3999072: #"{"id": 3999072, "name": "Annika Henderson", "profile": "Anika (born Annika Henderson; 6 February 1987 in Surrey, Eng", "namevariations": ["Anika Henderson", "Annika Henderson aka Anika"], "aliases": [{"id": 1982320, "name": "Anika (9)"}], "groups": [{"id": 4416371, "name": "A&R (3)"}, {"id": 4976319, "name": "Exploded View"}, {"id": 10356079, "name": "Monika Werkstatt"}], "images": [{"type": "primary"}]}"#,
        // Reto A Ichi
        6810891: #"{"id": 6810891, "name": "Reto A Ichi", "aliases": [{"id": 1918, "name": "Delarosa & Asora"}, {"id": 3722, "name": "Prefuse 73"}, {"id": 104331, "name": "Ahmad Szabo"}, {"id": 227795, "name": "Piano Overlord"}, {"id": 229415, "name": "Scott Herren"}, {"id": 1580833, "name": "The Predicate Production Guild"}], "images": [{"type": "primary"}]}"#,
    ]

    static func detail(_ id: Int) throws -> DiscogsArtistDetail {
        try JSONDecoder().decode(DiscogsArtistDetail.self, from: Data(entries[id]!.utf8))
    }

    static func facts(_ id: Int) throws -> DiscogsIdentityFacts {
        DiscogsIdentityFacts(detail: try detail(id))
    }

    static func allFacts() throws -> [DiscogsIdentityFacts] {
        try entries.keys.sorted().map(facts)
    }
}

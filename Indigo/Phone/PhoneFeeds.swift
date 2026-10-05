//
//  PhoneFeeds.swift
//  Indigo
//
//  Where each of the phone's feeds was left. A feed's page is rebuilt every
//  time its tab is chosen, so a position kept in the page went back to the
//  first slide; kept here, station seven is still station seven after a look
//  at For You, and the other way round.
//

import Observation

@MainActor
@Observable
final class PhoneFeeds {
    static let shared = PhoneFeeds()

    /// The station on screen in Live.
    var liveID: String?
    /// The suggestion on screen in For You.
    var forYouID: String?
    /// The station whose shows the Shows tab is showing; nil for the list of
    /// stations.
    var showsStation: String?

    /// Never freed; a main-actor deinit hop would abort if it were.
    nonisolated deinit {}
}

//
//  CloudKitSchemaManifest.swift
//  Indigo
//
//  The shape the synced schema is meant to have in CloudKit: every field of the
//  four models, and the CloudKit type it is stored as.
//
//  Written down because a deployed production schema cannot be changed, only
//  added to, so what is deployed has to be what was chosen and not whatever
//  SwiftData happened to generate. The types below are what the mapping is
//  expected to give -- SwiftData prefixes each field with `CD_`, and stores a
//  String, a UUID and a URL as STRING, an Int and a Bool as INT64, a Double as
//  DOUBLE, a Date as TIMESTAMP, and an array as BYTES. The first development
//  run reads the real types back and compares them with this list; a
//  difference there is settled before anything is deployed, and then this list
//  is what a later change is held to.
//
//  Read back from CloudKit's development environment on 2026-10-01 by
//  `CloudKitSeedRunner`: all 56 fields exist with the types below, and nothing
//  else but `CD_entityName`, a STRING on every record type, which is Core
//  Data's. A [String] is BYTES holding an NSKeyedArchiver archive of the
//  array's JSON. A UUID is its uuidString, a Bool is 0 or 1, a Date is the same
//  instant, and a string holding U+001F comes back scalar for scalar.
//

import Foundation

nonisolated enum CloudKitSchemaManifest {
    /// Entity -> field (the model's attribute name) -> CloudKit type.
    static let expected: [String: [String: String]] = [
        "CrateItem": [
            "id": "STRING", "kindRaw": "STRING", "addedAt": "TIMESTAMP",
            "matchKey": "STRING", "unknownCode": "STRING",
            "title": "STRING", "artistName": "STRING", "albumTitle": "STRING",
            "identificationStatusRaw": "STRING",
            "stationName": "STRING", "broadcastOffsetSeconds": "DOUBLE",
            "providerID": "STRING", "showID": "STRING", "showTitle": "STRING", "showSubtitle": "STRING",
            "artworkURLString": "STRING", "playbackURLString": "STRING", "embedProviderRaw": "STRING",
            "isLiveStream": "INT64", "genreTagsRaw": "STRING"
        ],
        "ListeningEvent": [
            "id": "STRING", "at": "TIMESTAMP", "actionRaw": "STRING",
            "nodeID": "STRING", "nodeKindRaw": "STRING", "nodeKey": "STRING",
            "title": "STRING", "subtitle": "STRING", "mbid": "STRING", "discogsID": "INT64",
            "providerID": "STRING", "handle": "STRING",
            "sourceProviderID": "STRING", "sourceShowID": "STRING", "sourceShowTitle": "STRING",
            "seconds": "DOUBLE", "completion": "DOUBLE", "tags": "BYTES"
        ],
        "DigVisit": [
            "id": "STRING", "nodeID": "STRING", "kindRaw": "STRING", "title": "STRING", "subtitle": "STRING",
            "visits": "INT64", "firstVisitedAt": "TIMESTAMP", "lastVisitedAt": "TIMESTAMP",
            "mbid": "STRING", "discogsID": "INT64", "providerID": "STRING", "handle": "STRING"
        ],
        "DigStep": [
            "id": "STRING", "identity": "STRING", "fromNodeID": "STRING", "toNodeID": "STRING",
            "count": "INT64", "lastAt": "TIMESTAMP"
        ],
        // V7. Additive: a new record type, nothing above changes.
        "DigCounter": [
            "id": "STRING", "kindRaw": "STRING", "key": "STRING", "deviceID": "STRING",
            "count": "INT64", "firstAt": "TIMESTAMP", "lastAt": "TIMESTAMP"
        ]
    ]

    /// What a Swift attribute type is expected to be stored as.
    static func expectedType(of valueType: Any.Type) -> String? {
        switch valueType {
        case is String.Type, is String?.Type, is UUID.Type, is UUID?.Type, is URL.Type, is URL?.Type: return "STRING"
        case is Int.Type, is Int?.Type, is Bool.Type, is Bool?.Type: return "INT64"
        case is Double.Type, is Double?.Type: return "DOUBLE"
        case is Date.Type, is Date?.Type: return "TIMESTAMP"
        case is [String].Type: return "BYTES"
        default: return nil
        }
    }

    /// The name CloudKit gives a model's field.
    static func fieldName(_ attribute: String) -> String { "CD_" + attribute }

    /// What a value read from a `CKRecord` is, in the vocabulary above.
    static func classify(_ value: Any) -> String {
        switch value {
        case is String: return "STRING"
        case is Date: return "TIMESTAMP"
        case is Data: return "BYTES"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "INT64" }
            return CFNumberIsFloatType(number) ? "DOUBLE" : "INT64"
        case is [Any]: return "LIST"
        default: return "OTHER(\(type(of: value)))"
        }
    }
}

//
//  DigWorker.swift
//  Indigo
//
//  The graph, walked somewhere other than the main thread.
//
//  Building a profile reads most of the store and walks every edge out of a
//  node. Done on the main actor — which is where a `@Model`-backed context
//  lives by default — that work happens between two frames, and the scroll
//  stops for as long as it takes. Moving it behind a `@ModelActor` gives it
//  its own context on its own executor, and the main thread only ever
//  receives the finished value.
//
//  Everything crossing that boundary is already a `Sendable` value type:
//  profiles, descents, scenes and connections are all plain structs built
//  from the store rather than references into it. That is what makes this a
//  change of thread rather than a change of design.
//

import Foundation
import SwiftData

@ModelActor
actor DigWorker {
    /// One engine, kept until something is written.
    ///
    /// Its caches are six whole tables, and a single page asks several
    /// questions — the profile, the descent, the scenes, the connections.
    /// Rebuilding that for each of them was most of the time it took to open
    /// anything.
    private var engine: DigEngine?
    private var deep: DeepEngine?
    private var scenes: SceneEngine?
    private var generation = -1

    private func refresh(_ asked: Int) {
        guard generation != asked else { return }
        engine = DigEngine(context: modelContext)
        deep = DeepEngine(context: modelContext)
        scenes = SceneEngine(context: modelContext)
        generation = asked
    }

    private func engine(_ asked: Int) -> DigEngine {
        refresh(asked)
        return engine ?? DigEngine(context: modelContext)
    }

    private func deepEngine(_ asked: Int) -> DeepEngine {
        refresh(asked)
        return deep ?? DeepEngine(context: modelContext)
    }

    private func sceneEngine(_ asked: Int) -> SceneEngine {
        refresh(asked)
        return scenes ?? SceneEngine(context: modelContext)
    }

    func artistProfile(name: String, mbid: String?, generation: Int) -> ArtistProfile {
        engine(generation).artistProfile(name: name, mbid: mbid)
    }

    func releaseProfile(id: Int, generation: Int) -> DigReleaseProfile? {
        engine(generation).releaseProfile(id: id)
    }

    func labelProfile(mbid: String, fallbackName: String, generation: Int) -> LabelProfile? {
        engine(generation).labelProfile(mbid: mbid, fallbackName: fallbackName)
    }

    func connections(from node: MusicNode, generation: Int) -> [MusicGraph.Connection] {
        engine(generation).connections(from: node)
    }

    func descent(from origin: MusicNode, at level: DeepLevel, generation: Int) -> DeepEngine.Descent {
        deepEngine(generation).descent(from: origin, at: level)
    }

    func undergroundCuts(for node: MusicNode, generation: Int) -> [DeepResult] {
        deepEngine(generation).results(from: node, at: .underground)
    }

    func scenes(forArtist name: String, generation: Int) -> [MusicScene] {
        sceneEngine(generation).scenes(forArtist: name)
    }

    func scene(city: String, generation: Int) -> MusicScene? {
        sceneEngine(generation).scene(city: city)
    }
}

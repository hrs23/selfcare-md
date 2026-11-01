import Foundation
import Testing
@testable import SelfcareCore

struct PreferencesTests {
    func decode(_ json: String) throws -> Preferences {
        try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    }

    @Test func emptyObjectGivesDefaults() throws {
        #expect(try decode("{}") == Preferences())
        #expect(try decode(#"{"health":{},"ai":{},"units":{}}"#) == Preferences())
    }

    @Test func missingKeysKeepTheOtherValues() throws {
        let p = try decode(#"""
        {"units":{"weight":"lb","distance":"mi","volume":"ml"},
         "enabledPacks":["a"],
         "health":{"autoImport":true,"requested":true},
         "ai":{"preset":"anthropic","customPrompt":"short"},
         "lastActiveDay":"2026-09-27"}
        """#)
        #expect(p.units.weight == .lb && p.units.distance == .mi && p.units.temperature == Preferences().units.temperature)
        #expect(p.enabledPacks == ["a"])
        #expect(p.health.autoImport && p.health.requested && p.health.anchors.isEmpty)
        #expect(p.ai.preset == .anthropic && p.ai.customPrompt == "short" && p.ai.imageGeneration)
        #expect(p.lastActiveDay == "2026-09-27" && p.timerCounts.isEmpty && p.modelCache.isEmpty)
    }

    @Test func unknownValueFallsBackForThatFieldOnly() throws {
        let p = try decode(#"{"ai":{"preset":"future","model":"m"},"units":{"weight":"stone","distance":"mi"}}"#)
        #expect(p.ai.preset == .openai && p.ai.model == "m")
        #expect(p.units.distance == .mi)
    }

    @Test func roundTrip() throws {
        var p = Preferences()
        p.ai.preset = .google
        p.health.anchors["x"] = Data([1])
        p.timerCounts["run"] = 2
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p)) == p)
    }

    @Test func loadNeverOverwritesWhatItCannotDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("preferences.json")

        let missing = Preferences.load(from: url)
        #expect(missing.preferences == Preferences() && missing.canSave)

        try Data(#"{"enabledPacks":["a"]}"#.utf8).write(to: url)
        let good = Preferences.load(from: url)
        #expect(good.preferences.enabledPacks == ["a"] && good.canSave)

        try Data("not json".utf8).write(to: url)
        let corrupt = Preferences.load(from: url)
        #expect(corrupt.preferences == Preferences() && corrupt.canSave)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: dir.appendingPathComponent(backups[0])) == Data("not json".utf8))

        try Data(#"{"enabledPacks":["a"]}"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let locked = Preferences.load(from: url)
        #expect(!locked.canSave)
    }
}

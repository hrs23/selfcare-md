import Foundation
import Testing
@testable import SelfcareCore

struct ValueTests {
    @Test(arguments: [
        ("12", "12"),
        ("30kg × 10", "30kg × 10"),
        ("20:00", "20:00"),
        ("5.0km × 28:00", "5.0km × 28:00"),
        ("20kg × 10 × 1:00", "20kg × 10 × 1:00"),
        ("18.5%", "18.5%"),
        ("120/80mmHg", "120/80mmHg"),
        ("250ml", "250ml"),
        ("22.5kg", "22.5kg"),
        ("-20kg", "-20kg"),
        ("5.25km", "5.25km"),
        ("400m", "400m"),
        ("0:45", "0:45"),
        ("1:30:45", "1:30:45"),
        ("152bpm", "152bpm"),
        ("97%", "97%"),
        ("1.5l", "1.5l"),
        ("320kcal", "320kcal"),
        ("36.5°C", "36.5°C"),
        ("97.7°F", "97.7°F"),
    ])
    func roundTrip(input: String, expected: String) throws {
        let v = try ValueParser.parse(input).get()
        #expect(v.text == expected)
    }

    @Test(arguments: [
        ("10 x 30kg", "30kg × 10"),
        ("３０ｋｇ×１０", "30kg × 10"),
        ("30 KG * 10", "30kg × 10"),
        ("45lbs x 10", "45lb × 10"),
        ("36.5℃", "36.5°C"),
        ("45s", "0:45"),
        ("90:00", "1:30:00"),
        ("5km", "5.0km"),
        ("30.00kg", "30kg"),
        ("18.50%", "18.5%"),
        ("", ""),
    ])
    func lenientReading(input: String, expected: String) throws {
        #expect(try ValueParser.parse(input).get().text == expected)
    }

    @Test(arguments: ["10.5", "10 furlongs", "-5", "-3km", "30kg × 40kg", "hello", "1:5", "30kg ×", "heavy"])
    func unreadable(input: String) {
        #expect((try? ValueParser.parse(input).get()) == nil)
    }

    @Test func conversion() {
        let prefs = UnitPreferences(weight: .kg, distance: .km, volume: .ml, temperature: .celsius)
        let lb = Quantity.weight(100, .lb).converted(to: prefs)
        #expect(lb.text == "45.36kg")
        #expect(Quantity.temperature(97.7, .fahrenheit).converted(to: prefs).text == "36.5°C")
        #expect(Quantity.distance(1, .mi).converted(to: prefs).text == "1.61km")
    }

    @Test func stepping() {
        #expect(Quantity.weight(30, .kg).stepped(1).text == "32.5kg")
        #expect(Quantity.reps(0).stepped(-1).text == "0")
        #expect(Quantity.duration(47).stepped(1).text == "0:50")
        #expect(Quantity.duration(47).stepped(-1).text == "0:45")
        #expect(Quantity.duration(60).stepped(1).text == "1:15")
        #expect(Quantity.distance(5.0, .km).stepped(1).text == "5.1km")
    }

    @Test func fieldOrder() {
        let v = Value([.duration(1680), .distance(5, .km), .heartRate(150)])
        #expect(v.text == "5.0km × 28:00 × 150bpm")
    }
}

struct MenuTests {
    let types: Set<String> = ["HKWorkoutActivityTypeRunning", "HKWorkoutActivityTypeWalking"]

    @Test func parsesMenu() {
        let text = """
        ---
        tags: [workout, lower-body]
        record: sets
        fields: [reps, weight]
        initial: 25kg × 10
        custom: keep me
        ---

        ![Squat](../media/Squat.gif)

        ## Form
        """
        let m = MenuFile(name: "Squat", text: text, appleHealthTypes: types)
        #expect(m.problems.isEmpty)
        #expect(m.record == .sets)
        #expect(m.fields == [.weight, .reps])
        #expect(m.tags == ["workout", "lower-body"])
        #expect(m.initial?.text == "25kg × 10")
        #expect(m.thumbnailReference == "../media/Squat.gif")
    }

    @Test func defaultsAndIgnores() {
        #expect(MenuFile(name: "A", text: "", appleHealthTypes: types).record == .check)
        let f = MenuFile(name: "B", text: "---\nfields: [weight, reps]\n---\n", appleHealthTypes: types)
        #expect(f.record == .check && f.fields == [.weight, .reps] && f.problems.isEmpty)
        let avoid = MenuFile(name: "C", text: "---\nrecord: avoid\nfields: [reps]\napple-health: HKWorkoutActivityTypeWalking\n---\n", appleHealthTypes: types)
        #expect(avoid.fields.isEmpty && avoid.appleHealth == nil && avoid.problems.isEmpty)
        let broken = MenuFile(name: "D", text: "---\nrecord: sets\nfields: [weight, reps]\ninitial: heavy\n---\n", appleHealthTypes: types)
        #expect(broken.initial == nil && broken.problems.isEmpty)
    }

    @Test(arguments: [
        "---\nrecord: [weight, reps]\n---\n",
        "---\nrecord: once\n---\n",
        "---\nfields: [weight, sets]\n---\n",
        "---\napple-health: running\n---\n",
        "---\nrecord: sets\n---\n",
        "---\nrecord: check\n",
    ])
    func problems(text: String) {
        #expect(MenuFile(name: "X", text: text, appleHealthTypes: types).hasProblem)
    }

    @Test func draftKeepsUnknownKeys() {
        let text = "---\ncustom: keep\nrecord: check\n---\n\nBody\n"
        let m = MenuFile(name: "X", text: text, appleHealthTypes: types)
        var d = MenuDraft(menu: m)
        d.record = .sets
        d.fields = [.reps, .weight]
        let out = d.text(updating: m.file)
        #expect(out == "---\ncustom: keep\nrecord: sets\nfields: [weight, reps]\n---\n\nBody\n")
    }

    @Test func names() {
        #expect(MenuName.validate("Squat") == nil)
        #expect(MenuName.validate("") != nil)
        #expect(MenuName.validate("a/b") != nil)
        #expect(MenuName.validate("a[[b") != nil)
        #expect(MenuName.validate("a[b") == nil)
        #expect(MenuName.validate("a#b") != nil)
    }
}

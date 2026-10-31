import Foundation
import Testing
@testable import KiteCore

@Suite struct JevTests {
    @Test func encodesQuestionsTheWayTheAPIWantsThem() throws {
        let body = try JSONValue.decode(Jev.requestBody(state: "s", questions: [
            "size": .choice(instructions: "How big", options: ["quick": "Q", "task": "T"]),
            "urgent": .noul(instructions: "It's urgent"),
        ]))
        #expect(body["model"]?.stringValue == "jev-latest" && body["state"]?.stringValue == "s")
        #expect(body["questions"]?["size"]?["type"]?.stringValue == "choice")
        #expect(body["questions"]?["size"]?["criteria"]?["quick"]?.stringValue == "Q")
        #expect(body["questions"]?["urgent"]?["type"]?.stringValue == "noul")
    }

    @Test func readsAnswers() throws {
        let answers = try Jev.answers(from: Data(#"""
            {"model":"jev-1.14.0","answers":{
              "size":{"type":"choice","choice":"quick","confidence":0.9,"probabilities":{"quick":0.95,"task":0.05}},
              "urgent":{"type":"noul","noul":0.04},
              "mood":{"type":"score","score":0.5}},
             "usage":{"input_tokens":10,"output_tokens":3}}
            """#.utf8))
        #expect(answers.choices["size"] == Jev.Choice(choice: "quick", confidence: 0.9, probabilities: ["quick": 0.95, "task": 0.05]))
        #expect(answers.nouls["urgent"] == 0.04)
        #expect(throws: Jev.BadResponse.self) { try Jev.answers(from: Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
    }

    @Test func routesOnlyConfidentQuickLookupsToTheFastModel() {
        func answers(_ choice: String, _ confidence: Double) -> Jev.Answers {
            Jev.Answers(choices: [Jev.routeQuestion: Jev.Choice(choice: choice, confidence: confidence, probabilities: [:])])
        }
        #expect(Jev.model(for: answers("quick", 0.9)) == "haiku")
        #expect(Jev.model(for: answers("quick", 0.5)) == nil)
        #expect(Jev.model(for: answers("task", 1)) == nil)
        #expect(Jev.model(for: Jev.Answers()) == nil)
        #expect(Jev.routing(goal: "g").state == "g")
    }

    @Test func picksElementsByProbability() {
        let candidates = [
            ElementFinder.Match(ref: "e1", line: "button \"Sign in\"", score: 0),
            ElementFinder.Match(ref: "e2", line: "button \"Proceed to payment\"", score: 0),
            ElementFinder.Match(ref: "e3", line: "link \"Help\"", score: 0),
        ]
        guard case let .choice(_, options)? = Jev.finding("checkout", among: candidates)[Jev.findQuestion] else {
            Issue.record("expected a choice")
            return
        }
        #expect(options["e2"] == "button \"Proceed to payment\"" && options.count == 3)
        let answers = Jev.Answers(choices: [Jev.findQuestion: Jev.Choice(
            choice: "e2", confidence: 0.8, probabilities: ["e2": 0.9, "e1": 0.08, "e3": 0.02, "e9": 0.5])])
        #expect(Jev.found(answers, among: candidates).map(\.ref) == ["e2", "e1"])
    }
}

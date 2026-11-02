import Foundation

/// TypeSafe's Jev (a "System One" model): typed answers (choice, score, true/false)
/// about some state, all questions at once, in well under a second. It can't write
/// text, so Kite uses it for the quick decisions around Claude, never instead of Claude.
///
/// This is the wire format only; the app does the HTTP call.
public enum Jev {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"

    public enum Question: Hashable, Sendable {
        /// Pick one option. `options` maps each option's name to what it means (at most 255).
        case choice(instructions: String, options: [String: String])
        /// Probability that the statement is true of the state.
        case noul(instructions: String)
    }

    public struct Choice: Hashable, Sendable {
        public var choice: String
        public var confidence: Double
        public var probabilities: [String: Double]
    }

    public struct Answers: Hashable, Sendable {
        public var choices: [String: Choice] = [:]
        public var nouls: [String: Double] = [:]
    }

    public static let maxOptions = 255

    public static func requestBody(state: String, questions: [String: Question]) -> Data {
        var encoded: [String: JSONValue] = [:]
        for (id, question) in questions {
            switch question {
            case let .choice(instructions, options):
                encoded[id] = ["type": "choice", "instructions": .string(instructions),
                               "criteria": .object(options.mapValues(JSONValue.string))]
            case .noul(let instructions):
                encoded[id] = ["type": "noul", "instructions": .string(instructions)]
            }
        }
        let body: JSONValue = ["state": .string(state), "model": .string(model), "questions": .object(encoded)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(body)) ?? Data()
    }

    public struct BadResponse: Error, CustomStringConvertible {
        public var description: String

        public init(description: String) {
            self.description = description
        }
    }

    public static func answers(from data: Data) throws -> Answers {
        let json = try JSONValue.decode(data)
        guard let answers = json["answers"]?.objectValue else {
            let message = json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue ?? json["detail"]?.stringValue
            throw BadResponse(description: message ?? "Jev sent no answers.")
        }
        var result = Answers()
        for (id, answer) in answers {
            switch answer["type"]?.stringValue {
            case "choice":
                guard let choice = answer["choice"]?.stringValue else { continue }
                result.choices[id] = Choice(
                    choice: choice, confidence: answer["confidence"]?.doubleValue ?? 0,
                    probabilities: (answer["probabilities"]?.objectValue ?? [:]).compactMapValues(\.doubleValue))
            case "noul":
                if let noul = answer["noul"]?.doubleValue { result.nouls[id] = noul }
            default:
                continue
            }
        }
        return result
    }
}

// MARK: Where Kite asks Jev

extension Jev {
    /// Claude Tasks: a quick lookup runs on a fast model; real multi-step work keeps the default.
    public enum TaskSize: String, Sendable {
        case quick, task
    }

    public static let routeQuestion = "size"

    public static func routing(goal: String) -> (state: String, questions: [String: Question]) {
        (goal, [routeQuestion: .choice(
            instructions: "How much browser work this request to a browser assistant needs",
            options: [
                TaskSize.quick.rawValue: "A quick lookup or question: read one or two pages and answer",
                TaskSize.task.rawValue: "Multi-step work: many sites or pages, comparing sources, filling forms, careful research",
            ])])
    }

    /// The fast model for a goal, or nil to keep Claude Code's default. Unsure answers keep the default.
    public static func model(for answers: Answers, minimumConfidence: Double = 0.7) -> String? {
        guard let size = answers.choices[routeQuestion], size.choice == TaskSize.quick.rawValue,
              size.confidence >= minimumConfidence else { return nil }
        return "haiku"
    }

    public static let findQuestion = "element"

    /// `find`: which of the page's elements the description means. Options are refs; their
    /// descriptions are the outline lines, so Jev reads `button "Add to cart"` and answers `e42`.
    public static func finding(_ query: String, among candidates: [ElementFinder.Match]) -> [String: Question] {
        var options: [String: String] = [:]
        for candidate in candidates.prefix(maxOptions) { options[candidate.ref] = candidate.line }
        return [findQuestion: .choice(instructions: "The page element that best matches: \(query)", options: options)]
    }

    /// The likeliest elements, best first, down to `floor` probability.
    public static func found(_ answers: Answers, among candidates: [ElementFinder.Match], limit: Int = 5,
                             floor: Double = 0.05) -> [ElementFinder.Match] {
        guard let answer = answers.choices[findQuestion] else { return [] }
        let byRef = Dictionary(candidates.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        return answer.probabilities
            .filter { $0.value >= floor }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { ref, probability in byRef[ref].map { ElementFinder.Match(ref: $0.ref, line: $0.line, score: probability) } }
    }
}

// MARK: Which space a link opens in

extension Jev {
    public static let spaceQuestion = "space"

    /// One space as Jev sees it: its name, and what `describe_space` says it's for.
    public struct SpaceOption: Hashable, Sendable {
        public var name: String
        public var about: String?

        public init(name: String, about: String?) {
            self.name = name
            self.about = about
        }
    }

    /// Claude opened a link for the user without naming a space (the routing rule asks it to,
    /// but it forgets). Jev reads the link against what each space is for. Nil when there's
    /// nothing to choose between: one space, no link, or no space that says what it's for.
    public static func spaceRouting(url: URL, spaces: [SpaceOption]) -> (state: String, questions: [String: Question])? {
        let named = spaces.filter { !$0.name.isEmpty }
        guard named.count > 1, named.contains(where: { !($0.about ?? "").isEmpty }),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var options: [String: String] = [:]
        for space in named.prefix(maxOptions) where options[space.name] == nil {
            let about = space.about?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            options[space.name] = about.isEmpty ? "The \(space.name) space" : about
        }
        return ("A link the user asked to open: \(url.absoluteString)", [spaceQuestion: .choice(
            instructions: "Which of the user's browser spaces this link belongs in, going by what each space is for",
            options: options)])
    }

    /// The space Jev picked, when it's sure enough to override where the tab would have gone.
    public static func space(from answers: Answers, minimumConfidence: Double = 0.75) -> String? {
        guard let answer = answers.choices[spaceQuestion], answer.confidence >= minimumConfidence else { return nil }
        return answer.choice
    }
}

// MARK: Instant Links

extension Jev {
    public static let searchAsTypedQuestion = "as_typed"

    /// Most of what's typed before ⇧⏎ is one thing to look up, and Google finds it as typed.
    /// Jev answers that in a fraction of a second, so only inputs that need rewriting (several
    /// things, a site to search on, a folder or a split) wait for Claude.
    public static func instantLinks(input: String) -> (state: String, questions: [String: Question]) {
        ("Typed into a browser's address bar: \(input)", [searchAsTypedQuestion: .noul(instructions: """
            This names exactly one thing to find; it doesn't name a website to search on, ask for several \
            results, or ask for a folder or a split view; so a Google search for it exactly as typed has the \
            page they want as its top result
            """)])
    }

    public static func searchAsTyped(_ answers: Answers, threshold: Double = 0.8) -> Bool {
        (answers.nouls[searchAsTypedQuestion] ?? 0) >= threshold
    }
}

// MARK: An extra check before Claude clicks

extension Jev {
    public static let commitsQuestion = "commits"

    /// With Ask Before Claude Acts on, a click Kite's word list lets through ("Continue",
    /// "Yes, I'm sure", an icon button) gets a second look. Jev can only add a question for the
    /// user, never take one away.
    public static func guardrail(click element: ElementDescription, host: String?) -> (state: String, questions: [String: Question]) {
        var lines = ["Site: \(host ?? "unknown")", "Element: \(element.summary)"]
        if let href = element.href, !href.isEmpty { lines.append("Link: \(href.prefix(200))") }
        if element.inForm { lines.append("Inside a form") }
        return (lines.joined(separator: "\n"), [commitsQuestion: .noul(instructions: """
            A browser assistant clicking this commits something the person can't easily take back: pays, buys, \
            places an order, sends or posts a message, deletes, submits an application or form, books, or \
            changes account or security settings
            """)])
    }

    public static func needsConfirmation(_ answers: Answers, threshold: Double = 0.85) -> Bool {
        (answers.nouls[commitsQuestion] ?? 0) >= threshold
    }
}

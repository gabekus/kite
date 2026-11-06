import Foundation

/// The user's ordinary form details, kept in one place in Kite: what Claude fills sign-ups, checkouts and account
/// forms from (Gabe, 5 Nov 2026: "anytime a form occurs, we should be filling this with Claude", after an agent took a
/// street from an old order email and typed the wrong one). Names, company, email, phone and named addresses only:
/// never a card number, a password, a code or an ID number, which stay with the user and their password manager.
///
/// Kept in the profile folder (`Form Profile.json`, readable only by the user), never synced. Claude reads it with
/// the `form_profile` tool; a change Claude asks for is shown to the user in Kite, who allows it (or not), so a value
/// read off an email can't become the truth by itself.
public struct FormProfile: Codable, Equatable, Sendable {
    public struct Address: Codable, Hashable, Sendable {
        /// What Claude asks for it by: "home", "makerspace".
        public var label: String
        public var street: String
        public var unit: String?
        public var city: String
        public var region: String
        public var postalCode: String
        public var country: String?
        /// When the user allowed it in Kite.
        public var confirmed: Date?

        public init(label: String, street: String, unit: String? = nil, city: String, region: String, postalCode: String,
                    country: String? = nil, confirmed: Date? = nil) {
            self.label = label
            self.street = street
            self.unit = unit
            self.city = city
            self.region = region
            self.postalCode = postalCode
            self.country = country
            self.confirmed = confirmed
        }

        public var oneLine: String {
            [street, unit, city, "\(region) \(postalCode)", country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    public var name: String?
    public var company: String?
    public var email: String?
    public var phone: String?
    public var addresses: [Address] = []

    public init(name: String? = nil, company: String? = nil, email: String? = nil, phone: String? = nil, addresses: [Address] = []) {
        self.name = name
        self.company = company
        self.email = email
        self.phone = phone
        self.addresses = addresses
    }

    public func address(_ label: String) -> Address? {
        addresses.first { $0.label.caseInsensitiveCompare(label.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    /// A change Claude asked for, applied: details it names replace the old ones, an address replaces the one with its label.
    public func merging(_ change: Change, confirmed: Date) -> FormProfile {
        var next = self
        if let v = change.name { next.name = v }
        if let v = change.company { next.company = v }
        if let v = change.email { next.email = v }
        if let v = change.phone { next.phone = v }
        if var address = change.address {
            address.confirmed = confirmed
            next.addresses.removeAll { $0.label.caseInsensitiveCompare(address.label) == .orderedSame }
            next.addresses.append(address)
        }
        return next
    }

    /// What form_profile set asks to change.
    public struct Change: Hashable, Sendable {
        public var name, company, email, phone: String?
        public var address: Address?

        public init(name: String? = nil, company: String? = nil, email: String? = nil, phone: String? = nil, address: Address? = nil) {
            self.name = name
            self.company = company
            self.email = email
            self.phone = phone
            self.address = address
        }

        public var isEmpty: Bool { [name, company, email, phone].allSatisfy { $0 == nil } && address == nil }

        /// For the user's Allow sheet.
        public var summary: String {
            var lines: [String] = []
            if let name { lines.append("Name: \(name)") }
            if let company { lines.append("Company: \(company)") }
            if let email { lines.append("Email: \(email)") }
            if let phone { lines.append("Phone: \(phone)") }
            if let address { lines.append("Address “\(address.label)”: \(address.oneLine)") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: For Claude

    /// What form_profile get returns.
    public var report: String {
        var lines = ["The user's form details (fill ordinary fields from these, never from emails, old orders or a guess):"]
        lines.append("- name: \(name ?? "(not set)")")
        lines.append("- company: \(company ?? "(not set)")")
        lines.append("- email: \(email ?? "(not set)")")
        lines.append("- phone: \(phone ?? "(not set)")")
        if addresses.isEmpty { lines.append("- addresses: none yet") }
        for a in addresses {
            lines.append("- address \"\(a.label)\": street \(a.street)" + (a.unit.map { ", unit \($0)" } ?? "")
                + ", city \(a.city), state \(a.region), ZIP \(a.postalCode)" + (a.country.map { ", country \($0)" } ?? "")
                + (a.confirmed == nil ? " (not confirmed by the user)" : ""))
        }
        lines.append("Cards, passwords, codes and ID numbers aren't here and never will be: those fields are the user's (handoff).")
        return lines.joined(separator: "\n")
    }

    /// Compares an address a page shows (or one Claude is about to enter) with the named one: what differs, word for word.
    public func check(_ shown: Address, against label: String) -> String {
        guard let saved = address(label) else { return "There's no address \"\(label)\" in the user's form details." }
        var differs: [String] = []
        func compare(_ field: String, _ a: String?, _ b: String?) {
            if Self.normalized(a) != Self.normalized(b) { differs.append("\(field): the page has “\(a ?? "")”, the user's is “\(b ?? "")”") }
        }
        compare("street", shown.street, saved.street)
        compare("unit", shown.unit, saved.unit)
        compare("city", shown.city, saved.city)
        compare("state", shown.region, saved.region)
        // ZIP+4 against a 5-digit ZIP is the same address.
        let zip = { (z: String) in String(z.filter(\.isNumber).prefix(5)) }
        if zip(shown.postalCode) != zip(saved.postalCode) {
            differs.append("ZIP: the page has “\(shown.postalCode)”, the user's is “\(saved.postalCode)”")
        }
        return differs.isEmpty
            ? "It matches the user's \"\(label)\" address."
            : "MISMATCH with the user's \"\(label)\" address. " + differs.joined(separator: "; ")
                + ". Correct the page to the user's address before going on."
    }

    /// Case, punctuation and the usual abbreviations don't count ("31st Ave." is "31st avenue"; "Apt 1L" is "1l").
    static func normalized(_ s: String?) -> String {
        let words = (s ?? "").lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        let short = ["avenue": "ave", "street": "st", "road": "rd", "boulevard": "blvd", "drive": "dr", "place": "pl",
                     "apartment": "", "apt": "", "unit": "", "suite": "", "ste": "", "building": "bldg", "number": "", "no": ""]
        return words.map { short[$0] ?? $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Something that must never be kept here: a card's or account's number (13 to 19 digits), or a field named for a secret.
    public static func looksSecret(_ value: String) -> Bool {
        value.filter(\.isNumber).count >= 13 && value.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
    }

    // MARK: Storage

    public static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Form Profile.json")
    }

    public static func load(from url: URL) -> FormProfile {
        guard let data = try? Data(contentsOf: url) else { return FormProfile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(FormProfile.self, from: data)) ?? FormProfile()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        // The user's own details: readable by them alone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension FormProfile {
    /// What Claude asks of form_profile.
    public enum Request: Hashable, Sendable {
        case get
        case set(Change)
        /// An address a page shows, against the user's address with this label.
        case check(Address, label: String)
    }

    static func parse(_ values: [String: JSONValue]) throws -> Request {
        typealias Invalid = AutomationCommand.InvalidArguments
        func text(_ object: [String: JSONValue], _ key: String) throws -> String? {
            guard let value = object[key], !value.isNull else { return nil }
            guard let s = value.stringValue else { throw Invalid("\"\(key)\" must be a string.") }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count <= 200 else { throw Invalid("\"\(key)\" is at most 200 characters.") }
            if looksSecret(t) { throw Invalid("\"\(key)\" looks like a card or account number: Kite never keeps those. They're the user's to type.") }
            return t.isEmpty ? nil : t
        }
        func address(_ value: JSONValue?, label fallback: String?) throws -> Address? {
            guard let value, !value.isNull else { return nil }
            guard let o = value.objectValue else { throw Invalid("\"address\" must be an object: {label, street, unit?, city, state, zip, country?}.") }
            guard let street = try text(o, "street"), let city = try text(o, "city"), let region = try text(o, "state"),
                  let zip = try text(o, "zip") else { throw Invalid("\"address\" needs street, city, state and zip.") }
            guard let label = try text(o, "label") ?? fallback else { throw Invalid("\"address\" needs a label, like \"home\".") }
            return Address(label: label, street: street, unit: try text(o, "unit"), city: city, region: region, postalCode: zip,
                           country: try text(o, "country"))
        }
        for key in ["password", "card", "card_number", "cvc", "cvv", "ssn", "ein", "code"] where values[key] != nil {
            throw Invalid("Kite never keeps \(key)s: those stay with the user and their password manager.")
        }
        switch try text(values, "action") ?? "get" {
        case "get": return .get
        case "set":
            let change = Change(name: try text(values, "name"), company: try text(values, "company"), email: try text(values, "email"),
                                phone: try text(values, "phone"), address: try address(values["address"], label: nil))
            guard !change.isEmpty else { throw Invalid("Pass what to set: name, company, email, phone or address.") }
            return .set(change)
        case "check":
            guard let label = try text(values, "label") else { throw Invalid("\"label\" names the user's address to check against, like \"home\".") }
            guard let shown = try address(values["address"], label: label) else { throw Invalid("\"address\" is what the page shows.") }
            return .check(shown, label: label)
        case let other: throw Invalid("\"action\" is get, set or check, not \"\(other)\".")
        }
    }
}

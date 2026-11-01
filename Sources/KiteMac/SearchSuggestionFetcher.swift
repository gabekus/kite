import Foundation
import KiteCore

/// Asks the search engine for suggestions as the command bar is typed in (Profile settings ›
/// "Include search engine suggestions"). No cookies are sent or kept.
enum SearchSuggestionFetcher {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// A test run's stand-in for the engine's endpoint (a 127.0.0.1 fixture), with
    /// `{searchTerms}` for the query. Only on a throwaway profile.
    private static var testTemplate: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KITE_SUPPORT_PATH"] != nil, let template = environment["KITE_TEST_SUGGEST_URL"],
              !template.isEmpty else { return nil }
        return template
    }

    static func suggestions(for query: String, engine: SearchEngine) async -> [String] {
        guard let url = SearchSuggestions.requestURL(for: query, engine: engine, template: testTemplate) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return SearchSuggestions.parse(data, query: query)
        } catch {
            return []
        }
    }
}

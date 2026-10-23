import Foundation
import Testing
@testable import KiteCore

@Suite struct AdblockStateTests {
    @Test func onByDefaultWithPerSiteOffSwitch() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let news = URL(string: "https://News.example.com/story")
        let other = URL(string: "https://other.example.com")

        #expect(state.blocksAds)
        #expect(state.blocksAds(on: news))
        #expect(!state.blocksAds(on: URL(string: "about:blank")))
        #expect(!state.blocksAds(on: nil))

        state.toggleAdblock(for: news)
        #expect(state.adblockAllowedHosts == ["news.example.com"])
        #expect(!state.blocksAds(on: news))
        #expect(state.blocksAds(on: other))

        state.toggleAdblock(for: news)
        #expect(state.blocksAds(on: news))
        #expect(state.adblockAllowedHosts.isEmpty)
    }

    @Test func shieldTurnsBlockingBackOnWhenOffGlobally() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let news = URL(string: "https://news.example.com")
        state.toggleAdblock(for: news)
        state.blocksAds = false
        #expect(!state.blocksAds(on: URL(string: "https://other.example.com")))

        state.toggleAdblock(for: news)
        #expect(state.blocksAds)
        #expect(state.blocksAds(on: news))
    }

    @Test func roundTripsAndDecodesOlderSessions() throws {
        var state = BrowserState.makeDefault()
        state.blocksAds = false
        state.adblockAllowedHosts = ["a.example"]
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["blocksAds"] = nil
        json["adblockAllowedHosts"] = nil
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.blocksAds)
        #expect(old.adblockAllowedHosts.isEmpty)
    }
}

@Suite struct FilterListTests {
    @Test func defaultsAreTheFourApprovedLists() {
        #expect(FilterList.defaults.map(\.id) == ["easylist", "easyprivacy", "ublock-filters", "ublock-quick-fixes"])
        #expect(FilterList.defaults.filter(\.trusted).map(\.id) == ["ublock-filters", "ublock-quick-fixes"])
        #expect(Set(FilterList.defaults.map(\.id)).count == FilterList.defaults.count)
    }

    @Test func refreshesDaily() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(FilterList.isRefreshDue(lastUpdated: nil, now: now))
        #expect(!FilterList.isRefreshDue(lastUpdated: now.addingTimeInterval(-3600), now: now))
        #expect(FilterList.isRefreshDue(lastUpdated: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(FilterList.isRefreshDue(lastUpdated: now.addingTimeInterval(3600), now: now))
    }

    @Test func rejectsPagesThatArentLists() {
        #expect(FilterList.looksValid("[Adblock Plus 2.0]\n! Title: EasyList\n||ads.example^"))
        #expect(FilterList.looksValid("! Title: uBlock filters\n"))
        #expect(!FilterList.looksValid("<!doctype html><title>Sign in to Wi-Fi</title>"))
    }
}

@Suite struct CosmeticTests {
    @Test func decodesAdblockRustJSON() throws {
        let json = ##"{"hide_selectors":["#ad"],"procedural_actions":[],"exceptions":[".ok"],"injected_script":"x()","generichide":true}"##
        let resources = try JSONDecoder().decode(CosmeticResources.self, from: Data(json.utf8))
        #expect(resources == CosmeticResources(hideSelectors: ["#ad"], exceptions: [".ok"], injectedScript: "x()", generichide: true))
    }

    @Test func oneRulePerSelector() {
        #expect(CosmeticResources.hidingCSS([".b", "#a"]) == "#a{display:none!important}\n.b{display:none!important}")
    }

    @Test func documentStartScriptGuardsTheHostAndEscapes() {
        let resources = CosmeticResources(hideSelectors: [#"a[href*="</script>"]"#], injectedScript: "scriptlet()")
        let script = resources.documentStartScript(host: "news.example.com", styleID: "k1", drain: "__kite")
        #expect(script.contains(#"location.hostname !== "news.example.com""#))
        #expect(script.contains("scriptlet()"))
        #expect(script.contains(#"const drainName = "__kite";"#))
        #expect(script.contains("MutationObserver"))
        #expect(!script.contains(#"href*="</script>"#))  // Selector text is escaped into a JSON string.

        let quiet = CosmeticResources(generichide: true).documentStartScript(host: "a.example", styleID: "k1", drain: "__kite")
        #expect(!quiet.contains("drainName"))
        #expect(!quiet.contains(#""__kite""#))
        // Running the script twice (a tab's first page) is a no-op the second time.
        #expect(quiet.contains(#"window["__kite_k1"]) return;"#))
    }
}

@Suite struct ScriptletBundleTests {
    private let files = [
        "resources/base.js": """
            export const registeredScriptlets = [];
            export const registerScriptlet = (fn, details) => {
                details.fn = fn;
                fn.details = details;
                if (Array.isArray(details.dependencies)) details.dependencies = details.dependencies.map(d => d.details.name);
                registeredScriptlets.push(details);
            };
            """,
        "resources/helper.js": """
            import { registerScriptlet } from './base.js';
            import { JSONPath as __JSONPath__ } from '../jsonpath.js';
            export const JSONPath = __JSONPath__;
            export function helperFn() { return 1; }
            registerScriptlet(helperFn, { name: 'helper.fn' });
            """,
        "jsonpath.js": "export class JSONPath {}\n",
        "resources/scriptlets.js": """
            import './helper.js';
            import {
                helperFn,
            } from './helper.js';
            import { registeredScriptlets } from './base.js';
            export const builtinScriptlets = registeredScriptlets;
            function setConstant(a) { return helperFn() + a; }
            builtinScriptlets.push({ name: 'set-constant.js', aliases: ['set.js'], fn: setConstant, dependencies: ['helper.fn'], requiresTrust: true });
            """,
    ]

    @Test func resolvesRelativeImports() {
        #expect(ScriptletBundle.resolve("../jsonpath.js", relativeTo: "resources/helper.js") == "jsonpath.js")
        #expect(ScriptletBundle.resolve("./base.js", relativeTo: "resources/helper.js") == "resources/base.js")
        #expect(ScriptletBundle.importedPaths(of: files["resources/helper.js"]!, at: "resources/helper.js")
            == ["resources/base.js", "jsonpath.js"])
    }

    @Test func ordersModulesAndRewritesImports() throws {
        let script = try ScriptletBundle.make(files: files)
        let base = try #require(script.range(of: "__module_resources_base_js = "))
        let helper = try #require(script.range(of: "__module_resources_helper_js = "))
        let entry = try #require(script.range(of: "__module_resources_scriptlets_js = "))
        #expect(base.lowerBound < helper.lowerBound && helper.lowerBound < entry.lowerBound)
        #expect(script.contains("const { JSONPath: __JSONPath__ } = __module_jsonpath_js;"))
        #expect(!script.contains("import "))
        #expect(!script.contains("export "))
        #expect(script.hasSuffix("var builtinScriptlets = __module_resources_scriptlets_js.builtinScriptlets;\n"))
    }

    @Test func reportsMissingModules() {
        var broken = files
        broken["jsonpath.js"] = nil
        #expect(throws: ScriptletBundle.BundleError.self) { try ScriptletBundle.make(files: broken) }
    }

    @Test func convertsDescriptionsToAdblockResources() throws {
        let description = #"[{"name":"set-constant.js","aliases":["set.js"],"source":"function setConstant(){}","dependencies":["helper.fn"],"requiresTrust":true},{"name":"helper.fn","aliases":[],"source":"function helperFn(){}","dependencies":[],"requiresTrust":false}]"#
        let json = try ScriptletBundle.resources(fromDescription: Data(description.utf8))
        let resources = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        #expect((resources[0]["kind"] as? [String: String]) == ["mime": "application/javascript"])
        #expect((resources[1]["kind"] as? [String: String]) == ["mime": "fn/javascript"])
        #expect(resources[0]["permission"] as? Int == 1)
        #expect(resources[1]["permission"] == nil)
        #expect(resources[0]["content"] as? String == Data("function setConstant(){}".utf8).base64EncodedString())
    }
}

@Suite struct ProceduralFilterTests {
    @Test func parsesAdblockRustSteps() throws {
        let json = #"{"selector":[{"type":"css-selector","arg":"[onclick] p"},{"type":"has-text","arg":"/Ad/"},{"type":"xpath","arg":"../../.."}]}"#
        let filter = try #require(ProceduralFilter(json: json))
        #expect(filter.selector.map(\.type) == ["css-selector", "has-text", "xpath"])
        #expect(filter.selector[2].arg == "../../..")
        #expect(filter.action == nil)
    }

    @Test func parsesActions() throws {
        let remove = try #require(ProceduralFilter(json: #"{"selector":[{"type":"css-selector","arg":".ad"}],"action":{"type":"remove"}}"#))
        #expect(remove.action == .init(type: "remove", arg: nil))
        let style = try #require(ProceduralFilter(json: #"{"selector":[{"type":"css-selector","arg":"body"}],"action":{"type":"style","arg":"overflow: auto !important"}}"#))
        #expect(style.action?.arg == "overflow: auto !important")
        let attr = try #require(ProceduralFilter(json: #"{"selector":[{"type":"css-selector","arg":"a"}],"action":{"type":"remove-attr","arg":"onclick"}}"#))
        #expect(attr.action?.type == "remove-attr")
    }

    @Test(arguments: [
        #"{"selector":[{"type":"css-selector","arg":"div"},{"type":"watch-attr","arg":"class"}]}"#,  // Unknown step.
        #"{"selector":[{"type":"css-selector","arg":"div"}],"action":{"type":"set-attr","arg":"x"}}"#,  // Unknown action.
        #"{"selector":[{"type":"has-text","arg":"Ad"}]}"#,  // Must start from a CSS selector.
        #"not json"#,
    ])
    func skipsFiltersKiteCantApply(json: String) {
        #expect(ProceduralFilter(json: json) == nil)
    }

    @Test func cosmeticResourcesKeepOnlyUsableFilters() throws {
        let json = #"""
            {"hide_selectors":[],"procedural_actions":[
              "{\"selector\":[{\"type\":\"css-selector\",\"arg\":\"div\"},{\"type\":\"upward\",\"arg\":\"2\"}]}",
              "{\"selector\":[{\"type\":\"css-selector\",\"arg\":\"div\"},{\"type\":\"future-step\",\"arg\":\"\"}]}"
            ],"exceptions":[],"injected_script":"","generichide":false}
            """#
        let resources = try JSONDecoder().decode(CosmeticResources.self, from: Data(json.utf8))
        #expect(resources.procedural.count == 1)
        #expect(resources.procedural[0].selector.last == .init(type: "upward", arg: "2"))
    }

    @Test func scriptRunsTheEngineOnlyWhenNeeded() {
        let plain = CosmeticResources(hideSelectors: [".ad"]).documentStartScript(host: "a.example", styleID: "k1", drain: nil)
        #expect(!plain.contains("const procedural"))

        let filter = ProceduralFilter(selector: [.init(type: "css-selector", arg: "h2"), .init(type: "has-text", arg: "Sponsored")])
        let script = CosmeticResources(procedural: [filter]).documentStartScript(host: "a.example", styleID: "k1", drain: nil)
        #expect(script.contains(#"const procedural = [{"selector":[{"#))
        #expect(script.contains("requestIdleCallback"))
        #expect(script.contains("'has-text'"))
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore

@Suite struct DocumentScriptSyntaxTests {
    /// The script is one unit: a syntax error would also lose the page's CSS and scriptlets.
    @Test func compilesInJavaScriptCore() throws {
        let filters = [
            ProceduralFilter(selector: [.init(type: "css-selector", arg: "h2"), .init(type: "has-text", arg: "/Promoted/i")]),
            ProceduralFilter(selector: [.init(type: "css-selector", arg: ".ad")], action: .init(type: "style", arg: "height: 0 !important")),
        ]
        let resources = CosmeticResources(hideSelectors: [#"a[href*="x"]"#], injectedScript: "function s(){}\ntry { s() } catch (e) {}", procedural: filters)
        let script = resources.documentStartScript(host: "a.example", styleID: "k1", drain: "__kite_q")
        let context = try #require(JSContext())
        context.setObject(script, forKeyedSubscript: "source" as NSString)
        let result = context.evaluateScript("try { new Function(source); 'ok' } catch (e) { String(e) }")
        #expect(result?.toString() == "ok")
        #expect(context.evaluateScript("try { new Function(\(Self.quoted(CosmeticResources.drainScript("__kite_q")))); 'ok' } catch (e) { String(e) }")?.toString() == "ok")
    }

    private static func quoted(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [s]), as: UTF8.self).dropFirst().dropLast().description
    }
}
#endif

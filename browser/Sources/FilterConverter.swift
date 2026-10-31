import Foundation

/// Translates Adblock-Plus-style filter lists (EasyList, EasyPrivacy …) into WebKit's
/// content-blocker JSON format – the same format Safari content blockers use.
///
/// Supported: address rules (`||domain^`, `|…`, wildcards), the common options
/// (third-party, resource types, domain=, match-case), exception rules (`@@`) and
/// element hiding (`##`). Not supported – these lines are skipped and counted:
/// regular-expression rules, script injection (`#$#`, `+js`), procedural selectors
/// (`:has-text`, `:-abp-…`), hiding exceptions (`#@#`) and options WebKit cannot express
/// (redirect, csp, removeparam …).
enum FilterConverter {
    static let version = 1

    struct Result {
        var rules: [[String: Any]] = []
        var blocking = 0
        var hiding = 0
        var exceptions = 0
        var skipped = 0
    }

    // MARK: Whole list

    static func convert(_ text: String, allowedSites: [String] = [], groupSize: Int = 50) -> Result {
        var result = Result()
        var blockRules: [[String: Any]] = [], exceptionRules: [[String: Any]] = []
        var genericSelectors: [String] = []
        var domainHiding: [[String: Any]] = []

        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return }

            // Element hiding and everything cosmetic.
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#")
                || line.contains("#@?#") || line.contains("##+js") || line.contains("#@$#") {
                result.skipped += 1; return
            }
            if let range = line.range(of: "##") {
                let domains = String(line[..<range.lowerBound])
                let selector = String(line[range.upperBound...])
                guard supportedSelector(selector) else { result.skipped += 1; return }
                if domains.isEmpty {
                    genericSelectors.append(selector)
                } else if let rule = hidingRule(selector: selector, domains: domains) {
                    domainHiding.append(rule)
                } else {
                    result.skipped += 1
                }
                return
            }

            // Address rules.
            guard let rule = networkRule(line) else { result.skipped += 1; return }
            if (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" {
                exceptionRules.append(rule)
            } else {
                blockRules.append(rule)
            }
        }

        // Generic hiding rules are grouped, so WebKit has fewer rules to check.
        var hiding = domainHiding
        var i = 0
        while i < genericSelectors.count {
            let group = genericSelectors[i..<min(i + groupSize, genericSelectors.count)]
            hiding.append(["trigger": ["url-filter": ".*"],
                           "action": ["type": "css-display-none", "selector": group.joined(separator: ", ")]])
            i += groupSize
        }

        result.blocking = blockRules.count
        result.hiding = domainHiding.count + genericSelectors.count
        result.exceptions = exceptionRules.count
        // Exceptions must come last: "ignore-previous-rules" only undoes rules listed before it.
        result.rules = blockRules + hiding + exceptionRules + allowedSites.map(allowSiteRule)
        return result
    }

    // MARK: Address rules

    static let allTypes = ["document", "image", "style-sheet", "script", "font", "raw", "svg-document",
                           "media", "popup", "ping", "other"]
    static let typeMap: [String: [String]] = [
        "script": ["script"], "image": ["image", "svg-document"], "stylesheet": ["style-sheet"],
        "font": ["font"], "media": ["media"], "xmlhttprequest": ["raw"], "websocket": ["raw"],
        "subdocument": ["document"], "document": ["document"], "popup": ["popup"], "ping": ["ping"],
        "other": ["other"], "object": ["other"], "object-subrequest": ["other"]
    ]

    static func networkRule(_ raw: String) -> [String: Any]? {
        var line = raw
        let isException = line.hasPrefix("@@")
        if isException { line.removeFirst(2) }

        var pattern = line
        var options: [String] = []
        if let dollar = line.lastIndex(of: "$") {
            pattern = String(line[..<dollar])
            options = line[line.index(after: dollar)...].split(separator: ",").map { $0.lowercased() }
        }
        // Regular-expression rules (/…/) cannot be translated reliably.
        if pattern.count > 2 && pattern.hasPrefix("/") && pattern.hasSuffix("/") { return nil }

        var trigger: [String: Any] = [:]
        var included = Set<String>(), excluded = Set<String>()
        var wholePageException = false

        for option in options {
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            switch name {
            case "third-party", "3p":
                trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "first-party", "1p":
                trigger["load-type"] = [negated ? "third-party" : "first-party"]
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "important", "all":
                break
            case "document" where isException && !negated:
                wholePageException = true
            case _ where name.hasPrefix("domain="):
                guard !negated, let domains = domainCondition(String(name.dropFirst(7)), separator: "|") else { return nil }
                trigger.merge(domains) { $1 }
            case _ where typeMap[name] != nil:
                if negated { excluded.formUnion(typeMap[name]!) } else { included.formUnion(typeMap[name]!) }
            default:
                return nil   // redirect, csp, removeparam, elemhide … – not possible in WebKit
            }
        }

        guard let filter = patternToRegex(pattern) else { return nil }

        if wholePageException {
            // "@@||site.com^$document": nothing is blocked on this site.
            return ["trigger": ["url-filter": ".*", "if-top-url": [filter]],
                    "action": ["type": "ignore-previous-rules"]]
        }

        // Without any other condition the pattern itself must be specific enough.
        let literal = filter.filter { $0.isLetter || $0.isNumber }
        if literal.count < 3 && trigger["if-domain"] == nil { return nil }

        trigger["url-filter"] = filter
        var types = included.isEmpty ? Set(allTypes) : included
        types.subtract(excluded)
        if types.isEmpty { return nil }
        if types.count < allTypes.count { trigger["resource-type"] = types.sorted() }

        return ["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]]
    }

    /// Adblock pattern → WebKit regular expression (WebKit supports only a small regex subset).
    static func patternToRegex(_ pattern: String) -> String? {
        guard !pattern.isEmpty, pattern.allSatisfy({ $0.isASCII }),
              !pattern.contains("{"), !pattern.contains("}") else { return nil }
        var s = Substring(pattern)
        var out = ""
        if s.hasPrefix("||") {
            out = "^[^:]+://+([^:/]+\\.)?"
            s = s.dropFirst(2)
        } else if s.hasPrefix("|") {
            out = "^"
            s = s.dropFirst()
        }
        var anchoredEnd = false
        if s.hasSuffix("|") {
            anchoredEnd = true
            s = s.dropLast()
        }
        if s.contains("|") { return nil }   // WebKit has no alternatives (a|b)
        for c in s {
            switch c {
            case "*": out += ".*"
            case "^": out += "[^-.%a-zA-Z0-9_]"   // Adblock "separator" character
            case ".", "?", "+", "(", ")", "[", "]", "\\", "$": out += "\\" + String(c)
            default: out.append(c)
            }
        }
        if anchoredEnd { out += "$" }
        while out.contains(".*.*") { out = out.replacingOccurrences(of: ".*.*", with: ".*") }
        if out.hasPrefix(".*") { out.removeFirst(2) }
        if out.hasSuffix(".*") && !out.hasSuffix("\\.*") { out.removeLast(2) }
        return out.isEmpty ? nil : out
    }

    // MARK: Element hiding

    private static let unsupportedSelectorParts = [
        ":-abp-", ":has-text", ":contains", ":xpath", ":matches-", ":upward", ":remove", ":style",
        ":watch-attr", ":min-text-length", ":others", ":if(", ":if-not", "+js(", ":nth-ancestor"
    ]

    static func supportedSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.allSatisfy({ $0.isASCII }) else { return false }
        return !unsupportedSelectorParts.contains { selector.contains($0) }
    }

    static func hidingRule(selector: String, domains: String) -> [String: Any]? {
        guard let condition = domainCondition(domains, separator: ",") else { return nil }
        var trigger: [String: Any] = ["url-filter": ".*"]
        trigger.merge(condition) { $1 }
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    /// "a.com|~b.com" → if-domain / unless-domain. WebKit can't combine both, so mixed lists
    /// keep only the positive part (blocks less, never more).
    static func domainCondition(_ list: String, separator: Character) -> [String: Any]? {
        var positive: [String] = [], negative: [String] = []
        for part in list.split(separator: separator) {
            var domain = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            guard !domain.isEmpty, domain.allSatisfy({ $0.isASCII }), !domain.contains("*"),
                  !domain.contains("/") else { continue }
            if negated { negative.append("*" + domain) } else { positive.append("*" + domain) }
        }
        if !positive.isEmpty { return ["if-domain": positive] }
        if !negative.isEmpty { return ["unless-domain": negative] }
        return nil
    }

    // MARK: Sites where the user switched blocking off

    static func allowSiteRule(_ host: String) -> [String: Any] {
        let escaped = host.map { ".?+()[]\\$^*|".contains($0) ? "\\\($0)" : String($0) }.joined()
        return ["trigger": ["url-filter": ".*", "if-top-url": ["^https?://([^/:]+\\.)?" + escaped + "[/:]"]],
                "action": ["type": "ignore-previous-rules"]]
    }

    static func json(_ rules: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

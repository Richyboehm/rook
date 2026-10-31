// Integration test for the ad blocker with the real filter lists and the real WebKit engine.
// Run with: browser/Tests/run-blocker.sh  (downloads the lists first)
import AppKit
import WebKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let names = ["easylist", "easyprivacy", "easylistgermany"]
let store = WKContentRuleListStore.default()!
var compiled: [WKContentRuleList] = []
var failures = 0

func check(_ ok: Bool, _ name: String) {
    print((ok ? "✓ " : "✗ ") + name)
    if !ok { failures += 1 }
}

/// Test page: a request to a well-known ad server, a request that must work, and an ad box.
let page = """
<!doctype html><html><body>
<div class="ad-slot" id="ad">Werbung</div><div class="content" id="ok">Inhalt</div>
<script>
async function probe(url) { try { await fetch(url, {mode: 'no-cors', cache: 'no-store'}); return 'geladen'; } catch (e) { return 'blockiert'; } }
async function run() {
  const ad = await probe('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js');
  const tracker = await probe('https://www.google-analytics.com/analytics.js');
  const normal = await probe('https://www.wikipedia.org/');
  const hidden = getComputedStyle(document.getElementById('ad')).display === 'none';
  const shown = getComputedStyle(document.getElementById('ok')).display !== 'none';
  return JSON.stringify({ad, tracker, normal, hidden, shown});
}
</script></body></html>
"""

final class Probe: NSObject, WKNavigationDelegate {
    let done: (String) -> Void
    init(done: @escaping (String) -> Void) { self.done = done }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        w.callAsyncJavaScript("return await run();", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result { self.done(value as? String ?? "") } else { self.done("") }
        }
    }
}

var keep: [Any] = []
func runPage(lists: [WKContentRuleList], then: @escaping ([String: Any]) -> Void) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    lists.forEach { config.userContentController.add($0) }
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
    let probe = Probe { json in
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        then(obj)
    }
    web.navigationDelegate = probe
    keep = [web, probe]
    web.loadHTMLString(page, baseURL: URL(string: "https://rook-test.example/")!)
}

func compileAll(allowed: [String], index: Int = 0, then: @escaping () -> Void) {
    guard index < names.count else { then(); return }
    let name = names[index]
    let text = (try? String(contentsOf: folder.appendingPathComponent("\(name).txt"), encoding: .utf8)) ?? ""
    let start = Date()
    let result = FilterConverter.convert(text, allowedSites: allowed)
    let convertTime = Date().timeIntervalSince(start)
    store.compileContentRuleList(forIdentifier: "rook-test-\(name)", encodedContentRuleList: FilterConverter.json(result.rules)) { list, error in
        let total = Date().timeIntervalSince(start)
        if let list {
            compiled.append(list)
            print(String(format: "  %@: %d Sperr-, %d Ausblend-, %d Ausnahmeregeln, %d übersprungen · Umwandeln %.1fs, gesamt %.1fs",
                         name, result.blocking, result.hiding, result.exceptions, result.skipped, convertTime, total))
        }
        check(list != nil, "\(name) wird von WebKit akzeptiert" + (error.map { " – Fehler: \($0.localizedDescription)" } ?? ""))
        compileAll(allowed: allowed, index: index + 1, then: then)
    }
}

let app = NSApplication.shared
print("Echte Filterlisten umwandeln und kompilieren …")
compileAll(allowed: []) {
    runPage(lists: compiled) { r in
        print("Testseite mit Blocker: \(r)")
        check(r["ad"] as? String == "blockiert", "Werbeserver (googlesyndication) wird blockiert")
        check(r["tracker"] as? String == "blockiert", "Tracker (google-analytics) wird blockiert")
        check(r["normal"] as? String == "geladen", "Normale Seite (wikipedia.org) lädt weiter")
        check(r["hidden"] as? Bool == true, "Werbekasten (.ad-slot) wird ausgeblendet")
        check(r["shown"] as? Bool == true, "Normaler Inhalt bleibt sichtbar")

        // Same lists, but the test site is on the "don't block here" list.
        compiled.removeAll()
        compileAll(allowed: ["rook-test.example"]) {
            runPage(lists: compiled) { r in
                print("Testseite mit Ausnahme: \(r)")
                check(r["ad"] as? String == "geladen", "Ausnahme pro Website: Werbeserver wird nicht blockiert")
                check(r["hidden"] as? Bool == false, "Ausnahme pro Website: Werbekasten bleibt sichtbar")
                names.forEach { store.removeContentRuleList(forIdentifier: "rook-test-\($0)") { _ in } }
                print(failures == 0 ? "\nAlle Blocker-Tests bestanden." : "\n\(failures) Blocker-Test(s) fehlgeschlagen.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(failures == 0 ? 0 : 1) }
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 300) { print("Zeitüberschreitung"); exit(1) }
app.run()

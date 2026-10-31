// Tests for Rook's safety-relevant logic. Run with: browser/Tests/run.sh
import AppKit
import WebKit

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print((condition ? "✓ " : "✗ ") + name)
    if !condition { failures += 1 }
}

// MARK: Address bar: web address or search?

UserDefaults.standard.removeObject(forKey: "engine")
check(Rook.url(forInput: "apple.com")?.absoluteString == "https://apple.com", "Domain wird zu https-Adresse")
check(Rook.url(forInput: "https://example.org/a?b=1")?.absoluteString == "https://example.org/a?b=1", "Vollständige Adresse bleibt unverändert")
check(Rook.url(forInput: "localhost:8080")?.absoluteString == "http://localhost:8080", "localhost wird zu http")
check(Rook.url(forInput: "wetter morgen")?.host == "www.google.com", "Text mit Leerzeichen wird gesucht")
check(Rook.url(forInput: "wetter morgen")?.absoluteString.contains("q=wetter%20morgen") == true, "Suchbegriff wird kodiert")
check(Rook.url(forInput: "a&b=c")?.absoluteString.contains("a%26b%3Dc") == true, "Sonderzeichen in Suche werden kodiert")
check(Rook.url(forInput: "javascript:alert(1)")?.host == "www.google.com", "javascript: in der Adressleiste wird nur gesucht, nicht ausgeführt")
check(Rook.url(forInput: "file:///etc/passwd")?.host == "www.google.com", "file: in der Adressleiste wird nur gesucht")
check(Rook.url(forInput: "   ") == nil, "Leere Eingabe macht nichts")
Rook.engine = "duckduckgo"
check(Rook.url(forInput: "test")?.host == "duckduckgo.com", "Gewählte Suchmaschine wird verwendet")
Rook.engine = "evil-engine"
check(Rook.engine == "duckduckgo", "Unbekannte Suchmaschine wird ignoriert")
UserDefaults.standard.removeObject(forKey: "engine")

// MARK: Links from websites

func kind(_ s: String) -> Rook.LinkKind { Rook.linkKind(for: URL(string: s)!) }
check(kind("https://example.com") == .web, "https bleibt im Browser")
check(kind("http://example.com") == .web, "http bleibt im Browser")
check(kind("rook://start/") == .startPage, "Startseite wird erkannt")
check(kind("mailto:a@b.de") == .otherApp, "mailto: braucht Bestätigung")
check(kind("zoommtg://join") == .otherApp, "Fremde App-Links brauchen Bestätigung")
check(kind("x-apple.systempreferences:com.apple.preference.security") == .otherApp, "Systemeinstellungen-Links brauchen Bestätigung")
check(kind("file:///Users/") == .blocked, "file: von Websites wird blockiert")
check(kind("javascript:alert(1)") == .blocked, "javascript: wird blockiert")
check(kind("JAVASCRIPT:alert(1)") == .blocked, "Großschreibung umgeht die Sperre nicht")

// MARK: Download file names

let folder = URL(fileURLWithPath: "/tmp/rook-test", isDirectory: true)
var existing: Set<String> = ["bericht.pdf", "bericht 2.pdf", "notiz"]
let exists: (URL) -> Bool = { existing.contains($0.lastPathComponent) }
check(Rook.uniqueDestination(in: folder, suggestedName: "neu.zip", exists: exists).lastPathComponent == "neu.zip", "Neuer Name bleibt")
check(Rook.uniqueDestination(in: folder, suggestedName: "bericht.pdf", exists: exists).lastPathComponent == "bericht 3.pdf", "Vorhandene Datei wird nicht überschrieben")
check(Rook.uniqueDestination(in: folder, suggestedName: "notiz", exists: exists).lastPathComponent == "notiz 2", "Auch ohne Endung kein Überschreiben")
check(Rook.uniqueDestination(in: folder, suggestedName: "../../.zshrc", exists: exists).deletingLastPathComponent().path == folder.path, "Pfadangaben im Namen werden ignoriert")
check(Rook.uniqueDestination(in: folder, suggestedName: "../../.zshrc", exists: exists).lastPathComponent == "zshrc", "Keine versteckten Dateien")
check(Rook.uniqueDestination(in: folder, suggestedName: "", exists: exists).lastPathComponent == "Download", "Leerer Name wird zu „Download“")

// MARK: Error texts

check(BrowserTab.explain(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)).0 == "Verbindung nicht sicher",
      "Zertifikatsfehler wird als unsicher erklärt")
check(BrowserTab.explain(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)).0 == "Keine Internetverbindung",
      "Offline wird verständlich erklärt")

// MARK: Website data

check(Rook.isStartPageRecord("start"), "Startseiten-Daten werden beim Löschen geschützt")
check(!Rook.isStartPageRecord("example.com"), "Website-Daten werden gelöscht")

// MARK: Ad blocker: filter conversion

func trigger(_ line: String) -> [String: Any]? { FilterConverter.networkRule(line)?["trigger"] as? [String: Any] }
func action(_ line: String) -> String? { (FilterConverter.networkRule(line)?["action"] as? [String: Any])?["type"] as? String }

check(trigger("||ads.example.com^")?["url-filter"] as? String == "^[^:]+://+([^:/]+\\.)?ads\\.example\\.com[^-.%a-zA-Z0-9_]",
      "Domain-Regel wird korrekt übersetzt")
check(action("||ads.example.com^") == "block", "Domain-Regel blockiert")
check((trigger("||t.com^$third-party")?["load-type"] as? [String]) == ["third-party"], "Option third-party")
check((trigger("||t.com^$~third-party")?["load-type"] as? [String]) == ["first-party"], "Option ~third-party")
check((trigger("||t.com^$script,image")?["resource-type"] as? [String]) == ["image", "script", "svg-document"], "Ressourcentypen")
check((trigger("||t.com^$~script")?["resource-type"] as? [String])?.contains("script") == false, "Ausgeschlossener Typ fehlt")
check((trigger("||t.com^$domain=a.com|b.com")?["if-domain"] as? [String]) == ["*a.com", "*b.com"], "domain= wird zu if-domain")
check((trigger("||t.com^$domain=~a.com")?["unless-domain"] as? [String]) == ["*a.com"], "domain=~ wird zu unless-domain")
check(FilterConverter.networkRule("||t.com^$redirect=noop.js") == nil, "Nicht übersetzbare Option wird übersprungen")
check(FilterConverter.networkRule("/ad[0-9]+/") == nil, "Regex-Regel wird übersprungen")
check(FilterConverter.networkRule("ab") == nil, "Zu allgemeine Regel wird übersprungen")
check(FilterConverter.networkRule("||münchen.de^") == nil, "Nicht-ASCII wird übersprungen")
check(trigger("/banner/*/ad_")?["url-filter"] as? String == "/banner/.*/ad_", "Platzhalter * wird zu .*")
check(action("@@||cdn.example.com/ads.js") == "ignore-previous-rules", "@@-Regel wird zur Ausnahme")
check((trigger("@@||good.com^$document")?["if-top-url"] as? [String])?.first?.contains("good\\.com") == true,
      "@@…$document schaltet die ganze Seite frei")

let sample = """
! Kommentar
[Adblock Plus 2.0]
||ads.example.com^
@@||ads.example.com/ok.js
##.ad-slot
##.werbung
example.com##.sponsor
##div:has-text(Anzeige)
example.com#@#.ad-slot
example.com##+js(nobab)
"""
let converted = FilterConverter.convert(sample, allowedSites: ["meine-seite.de"])
let types = converted.rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
check(converted.blocking == 1 && converted.exceptions == 1, "Liste: eine Sperr- und eine Ausnahmeregel")
check(converted.hiding == 3, "Liste: drei Ausblendregeln (zwei allgemein, eine für example.com)")
check(converted.skipped == 3, "Liste: drei nicht unterstützte Zeilen übersprungen")
check(types.first == "block" && types.last == "ignore-previous-rules", "Ausnahmen stehen am Ende")
check(types.filter { $0 == "css-display-none" }.count == 2, "Allgemeine Ausblendregeln werden gebündelt")
let lastTrigger = (converted.rules.last?["trigger"] as? [String: Any])?["if-top-url"] as? [String]
check(lastTrigger?.first?.contains("meine-seite\\.de") == true, "Ausnahme pro Website steht ganz am Ende")
check(ContentBlocker.site(of: URL(string: "https://www.spiegel.de/x")) == "spiegel.de", "Website-Name ohne www.")
check(ContentBlocker.site(of: URL(string: "rook://start/")) == nil, "Startseite hat keine Ausnahme")
let blocker = ContentBlocker.shared
let listsBefore = blocker.disabledLists
blocker.setList("easyprivacy", enabled: false)
check(blocker.disabledLists.contains("easyprivacy"), "Tracker-Liste lässt sich einzeln ausschalten")
blocker.setList("easyprivacy", enabled: true)
check(!blocker.disabledLists.contains("easyprivacy"), "Tracker-Liste lässt sich wieder einschalten")
blocker.setList("boese-liste", enabled: false)
check(!blocker.disabledLists.contains("boese-liste"), "Unbekannte Liste wird ignoriert")
blocker.disabledLists = listsBefore

// MARK: Settings interface: only the start page may use it

func apiRequest(_ url: String, from page: String?) -> URLRequest {
    var r = URLRequest(url: URL(string: url)!)
    r.mainDocumentURL = page.flatMap(URL.init(string:))
    return r
}
check(BrowserAPI.isAllowed(apiRequest("rook://start/api/clear-history", from: "rook://start/")), "Startseite darf die Schnittstelle nutzen")
check(!BrowserAPI.isAllowed(apiRequest("rook://start/api/clear-history", from: "https://boese.example/")), "Fremde Website darf den Verlauf nicht löschen")
check(!BrowserAPI.isAllowed(apiRequest("rook://start/api/settings.json", from: nil)), "Anfrage ohne Herkunft wird abgelehnt")

print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
exit(failures == 0 ? 0 : 1)

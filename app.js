/* Rook – a beautiful, private new tab page.
 * Everything is stored locally in your browser (localStorage). No account, no server, no tracking.
 * MIT License – see LICENSE.
 */
(function () {
  "use strict";

  var KEY = "rook.v1";
  var BG_KEY = "rook.bg"; // custom background image (data URL), stored separately because it is large

  // ---------------------------------------------------------------- texts

  var I18N = {
    en: {
      searchWith: "Search with {engine} or enter an address",
      morning: "Good morning", day: "Good afternoon", evening: "Good evening", night: "Good night",
      add: "Add", edit: "Edit", addFav: "Add favorite", editFav: "Edit favorite",
      name: "Name", address: "Address", delete: "Delete", cancel: "Cancel", save: "Save", done: "Done",
      confirmDelete: "Delete “{name}”?", invalidUrl: "Please enter a valid web address (http or https).",
      settings: "Settings", general: "General", language: "Language", auto: "Automatic", yourName: "Your name",
      showClock: "Show time and greeting", showLogo: "Show Rook logo", search: "Search", engine: "Search engine", look: "Look",
      dim: "Darken background", accent: "Accent color", privacy: "Privacy",
      loadIcons: "Load website logos",
      loadIconsHint: "Logos are fetched from Google’s favicon service, which sees which sites are on your page. Turn this off to show letters instead.",
      backup: "Backup", export: "Export", import: "Import …", restartOnboarding: "Show welcome again",
      resetAll: "Reset everything", confirmReset: "Reset Rook? Your favorites and settings will be removed.",
      importFailed: "This file is not a valid Rook backup.", imageTooBig: "This image is too large. Please choose a smaller one.",
      editHint: "Tip: hover a favorite and click ✎ to edit it, drag to reorder. Press / to search, 1 to 9 to open a favorite.",
      ownImage: "Own image …", skip: "Skip", back: "Back", next: "Next", letsGo: "Done",
      welcomeTitle: "Welcome to Rook",
      welcomeText: "A few settings and you are ready. Everything stays on this device.",
      whatName: "Your name", namePlaceholder: "Optional",
      engineTitle: "Search engine", engineText: "Your searches are sent here. You can change it later in the settings.",
      bgTitle: "Background", bgText: "Choose a motif or one of your own photos.",
      favTitle: "Favorites", favText: "Select the sites you visit often. You can add more later.",
      settingsLabel: "Settings",
      engGoogle: "Most results. Stores searches for advertising.", engDuck: "No tracking, no profiles.",
      engStartpage: "Google results, requested anonymously.", engEcosia: "Uses ad revenue to plant trees.",
      engBing: "Search engine by Microsoft.", engBrave: "Own index, no tracking.",
      introApp: "A lean browser for the Mac, built on the Safari engine. Ads and trackers are blocked before they load, and your data stays on this device.",
      introWeb: "A calm start page for your browser. No account, no tracking. Everything stays on this device.",
      introGo: "Get started",
      blockerTitle: "Ad blocker", blockerText: "Rook blocks ads and trackers inside the Safari engine, before a page loads. The filter lists come from EasyList and are updated weekly.",
      listEasylist: "Ads", listEasylistDesc: "Banners and pop-ups on most websites.",
      listEasyprivacy: "Trackers", listEasyprivacyDesc: "Stops companies from following you across websites.",
      listEasylistgermany: "German websites", listEasylistgermanyDesc: "Extra rules for ads on German sites.",
      blockerHint: "If a site does not work properly, turn the blocker off there with the shield in the address bar.",
      filterLists: "Filter lists", update: "Update", history: "History", cookies: "Cookies and website data",
      cookiesHint: "Signs you out of all websites", exportSettings: "Save a backup", importSettings: "Load a backup",
      recent: "Recently visited", weather: "Weather", showWeather: "Show weather", weatherCity: "City",
      weatherHint: "For this, your city is sent to open-meteo.com (free weather service, no account). Off by default.",
      weatherError: "Weather not available",
      tabLook: "Look", tabStart: "Start page", tabBrowser: "Browser", tabPrivacy: "Privacy",
      background: "Background", greetingTitle: "Greeting", startContent: "Shown on the start page",
      showFavs: "Favorites", showRecent: "Recently visited",
      downloads: "Downloads", downloadFolder: "Save to", change: "Change …", showInFinder: "Show in Finder",
      standardFolder: "Default", askWhereToSave: "Ask where to save every download",
      downloadsHint: "Downloads are never opened automatically. macOS checks them the first time you open them.",
      tabsTitle: "Tabs", restoreSession: "Reopen the tabs from last time when Rook starts",
      defaultBrowser: "Default browser", isDefault: "Rook is your default browser.", notDefault: "Another browser is your default browser.",
      makeDefault: "Make Rook the default browser", importBookmarks: "Import bookmarks …",
      appOnlyHint: "Downloads, ad blocker and history settings are available in the Rook app for Mac.",
      blocker: "Ad & tracker blocker", blockerToggle: "Block ads and trackers", updateLists: "Update filter lists now",
      updating: "Updating …", exceptions: "Not blocked on these sites", noExceptions: "None. Rook blocks on every website.",
      remove: "Remove", historyTitle: "History and website data", historyInfo: "{n} pages",
      clearHistory: "Delete history completely", clearData: "Delete cookies & website data",
      confirmClearHistory: "Delete your entire history? Visited pages, recently closed tabs, address bar suggestions and “Recently visited” are removed from this Mac. This cannot be undone.",
      confirmClearData: "Delete all cookies and website data? You will be signed out of all websites. Your start page stays as it is.",
      historyCleared: "History deleted.", dataCleared: "Cookies and website data deleted.",
      sitePermissions: "Camera, microphone & zoom per website", noSitePermissions: "No website settings yet",
      camera: "Camera", microphone: "Microphone", allowed: "allowed", denied: "denied", zoom: "Zoom", reset: "Reset"
    },
    de: {
      searchWith: "Mit {engine} suchen oder Adresse eingeben",
      morning: "Guten Morgen", day: "Guten Tag", evening: "Guten Abend", night: "Gute Nacht",
      add: "Hinzufügen", edit: "Bearbeiten", addFav: "Favorit hinzufügen", editFav: "Favorit bearbeiten",
      name: "Name", address: "Adresse", delete: "Löschen", cancel: "Abbrechen", save: "Sichern", done: "Fertig",
      confirmDelete: "„{name}“ löschen?", invalidUrl: "Bitte eine gültige Webadresse eingeben (http oder https).",
      settings: "Einstellungen", general: "Allgemein", language: "Sprache", auto: "Automatisch", yourName: "Dein Name",
      showClock: "Uhrzeit und Begrüßung anzeigen", showLogo: "Rook-Logo anzeigen", search: "Suche", engine: "Suchmaschine", look: "Aussehen",
      dim: "Hintergrund abdunkeln", accent: "Akzentfarbe", privacy: "Datenschutz",
      loadIcons: "Logos der Websites laden",
      loadIconsHint: "Die Logos kommen vom Favicon-Dienst von Google. Google sieht dadurch, welche Seiten auf deiner Startseite sind. Ausgeschaltet erscheinen stattdessen Buchstaben.",
      backup: "Sicherung", export: "Exportieren", import: "Importieren …", restartOnboarding: "Begrüßung erneut zeigen",
      resetAll: "Alles zurücksetzen", confirmReset: "Rook zurücksetzen? Deine Favoriten und Einstellungen werden gelöscht.",
      importFailed: "Diese Datei ist keine gültige Rook-Sicherung.", imageTooBig: "Das Bild ist zu groß. Bitte ein kleineres wählen.",
      editHint: "Tipp: Mit der Maus über einen Favoriten fahren und auf ✎ klicken, zum Umsortieren ziehen. / springt in die Suche, 1 bis 9 öffnet Favoriten.",
      ownImage: "Eigenes Bild …", skip: "Überspringen", back: "Zurück", next: "Weiter", letsGo: "Fertig",
      welcomeTitle: "Willkommen bei Rook",
      welcomeText: "Ein paar Einstellungen, dann kann es losgehen. Alles bleibt auf diesem Gerät.",
      whatName: "Dein Name", namePlaceholder: "Optional",
      engineTitle: "Suchmaschine", engineText: "Hierhin gehen deine Suchanfragen. Du kannst das später in den Einstellungen ändern.",
      bgTitle: "Hintergrund", bgText: "Wähle ein Motiv oder ein eigenes Foto.",
      favTitle: "Favoriten", favText: "Wähle die Seiten, die du oft besuchst. Weitere kannst du später hinzufügen.",
      settingsLabel: "Einstellungen",
      engGoogle: "Die meisten Ergebnisse. Speichert Suchanfragen für Werbung.", engDuck: "Kein Tracking, keine Profile.",
      engStartpage: "Google-Ergebnisse, anonym abgefragt.", engEcosia: "Finanziert mit Werbeeinnahmen Baumpflanzungen.",
      engBing: "Suchmaschine von Microsoft.", engBrave: "Eigener Index, kein Tracking.",
      introApp: "Ein schlanker Browser für den Mac, gebaut auf der Safari-Engine. Werbung und Tracker werden blockiert, bevor sie laden, und deine Daten bleiben auf diesem Gerät.",
      introWeb: "Eine ruhige Startseite für deinen Browser. Kein Konto, kein Tracking. Alles bleibt auf diesem Gerät.",
      introGo: "Loslegen",
      blockerTitle: "Werbeblocker", blockerText: "Rook blockiert Werbung und Tracker direkt in der Safari-Engine, bevor eine Seite lädt. Die Filterlisten stammen von EasyList und werden wöchentlich aktualisiert.",
      listEasylist: "Werbung", listEasylistDesc: "Banner und Pop-ups auf den meisten Websites.",
      listEasyprivacy: "Tracker", listEasyprivacyDesc: "Verhindert, dass Firmen dir über Websites hinweg folgen.",
      listEasylistgermany: "Deutsche Websites", listEasylistgermanyDesc: "Zusätzliche Regeln für Werbung auf deutschen Seiten.",
      blockerHint: "Funktioniert eine Seite nicht richtig, schalte den Blocker dort über das Schild in der Adressleiste aus.",
      filterLists: "Filterlisten", update: "Aktualisieren", history: "Verlauf", cookies: "Cookies und Website-Daten",
      cookiesHint: "Meldet dich auf allen Websites ab", exportSettings: "Sicherung speichern", importSettings: "Sicherung laden",
      recent: "Zuletzt besucht", weather: "Wetter", showWeather: "Wetter anzeigen", weatherCity: "Stadt",
      weatherHint: "Dafür wird deine Stadt an open-meteo.com geschickt (kostenloser Wetterdienst, kein Konto). Standardmäßig aus.",
      weatherError: "Wetter nicht verfügbar",
      tabLook: "Aussehen", tabStart: "Startseite", tabBrowser: "Browser", tabPrivacy: "Datenschutz",
      background: "Hintergrund", greetingTitle: "Begrüßung", startContent: "Auf der Startseite anzeigen",
      showFavs: "Favoriten", showRecent: "Zuletzt besucht",
      downloads: "Downloads", downloadFolder: "Speichern in", change: "Ändern …", showInFinder: "Im Finder zeigen",
      standardFolder: "Standard", askWhereToSave: "Vor jedem Download fragen, wo gespeichert wird",
      downloadsHint: "Downloads werden nie automatisch geöffnet. macOS prüft sie beim ersten Öffnen.",
      tabsTitle: "Tabs", restoreSession: "Tabs vom letzten Mal beim Start wieder öffnen",
      defaultBrowser: "Standardbrowser", isDefault: "Rook ist dein Standardbrowser.", notDefault: "Ein anderer Browser ist dein Standardbrowser.",
      makeDefault: "Rook als Standardbrowser festlegen", importBookmarks: "Lesezeichen importieren …",
      appOnlyHint: "Einstellungen zu Downloads, Werbeblocker und Verlauf gibt es in der Rook-App für den Mac.",
      blocker: "Werbe- und Trackingschutz", blockerToggle: "Werbung und Tracker blockieren", updateLists: "Filterlisten jetzt aktualisieren",
      updating: "Wird aktualisiert …", exceptions: "Auf diesen Websites nicht blockieren", noExceptions: "Keine. Rook blockiert auf allen Websites.",
      remove: "Entfernen", historyTitle: "Verlauf und Website-Daten", historyInfo: "{n} Seiten",
      clearHistory: "Verlauf restlos löschen", clearData: "Cookies und Website-Daten löschen",
      confirmClearHistory: "Den gesamten Verlauf löschen? Besuchte Seiten, zuletzt geschlossene Tabs, Vorschläge in der Adressleiste und „Zuletzt besucht“ werden von diesem Mac entfernt. Das lässt sich nicht rückgängig machen.",
      confirmClearData: "Alle Cookies und Website-Daten löschen? Du wirst auf allen Websites abgemeldet. Deine Startseite bleibt, wie sie ist.",
      historyCleared: "Verlauf gelöscht.", dataCleared: "Cookies und Website-Daten gelöscht.",
      sitePermissions: "Kamera, Mikrofon und Zoom pro Website", noSitePermissions: "Noch keine Website-Einstellungen",
      camera: "Kamera", microphone: "Mikrofon", allowed: "erlaubt", denied: "abgelehnt", zoom: "Zoom", reset: "Zurücksetzen"
    }
  };

  // ---------------------------------------------------------------- data

  var ENGINES = {
    google: { name: "Google", url: "https://www.google.com/search?q=", desc: "engGoogle" },
    duckduckgo: { name: "DuckDuckGo", url: "https://duckduckgo.com/?q=", desc: "engDuck" },
    startpage: { name: "Startpage", url: "https://www.startpage.com/do/search?q=", desc: "engStartpage" },
    ecosia: { name: "Ecosia", url: "https://www.ecosia.org/search?q=", desc: "engEcosia" },
    bing: { name: "Bing", url: "https://www.bing.com/search?q=", desc: "engBing" },
    brave: { name: "Brave Search", url: "https://search.brave.com/search?q=", desc: "engBrave" }
  };

  var BACKGROUNDS = [
    { id: "obsidian", name: "Obsidian" },
    { id: "aurora", name: "Aurora" },
    { id: "ember", name: "Ember" },
    { id: "midnight", name: "Midnight" }
  ];

  var ACCENTS = ["#0a84ff", "#bf5af2", "#ff375f", "#ff9f0a", "#30d158", "#8e8e93"];

  function presets(lang) {
    return [
      { name: "Google", url: "https://www.google.com" },
      { name: "YouTube", url: "https://www.youtube.com" },
      { name: "Gmail", url: "https://mail.google.com" },
      { name: "Outlook", url: "https://outlook.live.com" },
      { name: "WhatsApp", url: "https://web.whatsapp.com" },
      { name: "Instagram", url: "https://www.instagram.com" },
      { name: "Netflix", url: "https://www.netflix.com" },
      { name: "Spotify", url: "https://open.spotify.com" },
      { name: "Amazon", url: lang === "de" ? "https://www.amazon.de" : "https://www.amazon.com" },
      { name: "Wikipedia", url: "https://" + lang + ".wikipedia.org" },
      { name: "Reddit", url: "https://www.reddit.com" },
      { name: "GitHub", url: "https://github.com" },
      { name: "ChatGPT", url: "https://chatgpt.com" },
      { name: "Claude", url: "https://claude.ai" },
      { name: "LinkedIn", url: "https://www.linkedin.com" },
      { name: "X", url: "https://x.com" },
      { name: "Maps", url: "https://maps.google.com" },
      { name: "Drive", url: "https://drive.google.com" },
      { name: "Twitch", url: "https://www.twitch.tv" },
      { name: "Notion", url: "https://www.notion.so" },
      { name: "Pinterest", url: "https://www.pinterest.com" }
    ];
  }
  var DEFAULT_PICKS = ["YouTube", "Gmail", "Wikipedia", "Netflix", "Amazon", "Spotify"];

  // ---------------------------------------------------------------- state

  function detectLang() {
    return /^de\b/i.test(navigator.language || "") ? "de" : "en";
  }

  function defaults() {
    var lang = detectLang();
    return {
      version: 1, onboarded: false, lang: "auto", name: "", showClock: true, showLogo: true,
      engine: "google", engineChangedAt: 0, bg: "obsidian", dim: 30, accent: ACCENTS[0], icons: true,
      weatherOn: false, weatherCity: "", showFavs: true, showRecent: true,
      favorites: presets(lang).filter(function (p) { return DEFAULT_PICKS.indexOf(p.name) >= 0; })
    };
  }

  // Only accept known fields with the right types – protects against broken or malicious backups.
  function sanitize(raw) {
    var d = defaults(), s = {};
    raw = raw && typeof raw === "object" ? raw : {};
    s.version = 1;
    s.onboarded = raw.onboarded === true;
    s.lang = ["auto", "en", "de"].indexOf(raw.lang) >= 0 ? raw.lang : d.lang;
    s.name = typeof raw.name === "string" ? raw.name.slice(0, 30) : d.name;
    s.showClock = typeof raw.showClock === "boolean" ? raw.showClock : d.showClock;
    s.showLogo = typeof raw.showLogo === "boolean" ? raw.showLogo : d.showLogo;
    s.engine = ENGINES[raw.engine] ? raw.engine : d.engine;
    s.bg = raw.bg === "custom" || BACKGROUNDS.some(function (b) { return b.id === raw.bg; }) ? raw.bg : d.bg;
    s.dim = typeof raw.dim === "number" && raw.dim >= 0 && raw.dim <= 80 ? raw.dim : d.dim;
    s.accent = /^#[0-9a-f]{6}$/i.test(raw.accent) ? raw.accent : d.accent;
    s.icons = typeof raw.icons === "boolean" ? raw.icons : d.icons;
    s.engineChangedAt = typeof raw.engineChangedAt === "number" ? raw.engineChangedAt : 0;
    s.weatherOn = raw.weatherOn === true;
    s.showFavs = raw.showFavs !== false;
    s.showRecent = raw.showRecent !== false;
    s.weatherCity = typeof raw.weatherCity === "string" ? raw.weatherCity.slice(0, 60) : "";
    s.favorites = Array.isArray(raw.favorites) ? raw.favorites.map(function (f) {
      var url = f && safeUrl(f.url);
      return url && typeof f.name === "string" && f.name.trim() ? { name: f.name.trim().slice(0, 40), url: url } : null;
    }).filter(Boolean).slice(0, 60) : d.favorites;
    return s;
  }

  function load() {
    try {
      var raw = localStorage.getItem(KEY);
      if (raw) return sanitize(JSON.parse(raw));
    } catch (e) {}
    return defaults();
  }
  function save() {
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {}
  }
  function customBg() { try { return localStorage.getItem(BG_KEY); } catch (e) { return null; } }

  var state = load();

  // ---------------------------------------------------------------- helpers

  var $ = function (id) { return document.getElementById(id); };

  function lang() { return state.lang === "auto" ? detectLang() : state.lang; }
  function t(key, vars) {
    var s = (I18N[lang()] || I18N.en)[key] || I18N.en[key] || key;
    if (vars) for (var k in vars) s = s.replace("{" + k + "}", vars[k]);
    return s;
  }
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  // Returns a clean http(s) URL or null. Blocks javascript:, data: and other schemes.
  function safeUrl(input) {
    if (typeof input !== "string") return null;
    var v = input.trim();
    if (!v || /\s/.test(v)) return null;
    if (!/^[a-z][a-z0-9+.-]*:/i.test(v)) v = "https://" + v;
    try {
      var u = new URL(v);
      return (u.protocol === "https:" || u.protocol === "http:") && u.hostname.indexOf(".") > 0 ? u.href : null;
    } catch (e) { return null; }
  }
  function looksLikeUrl(v) {
    return !/\s/.test(v) && (/^https?:\/\//i.test(v) || /^[\w-]+(\.[\w-]+)+(:\d+)?(\/\S*)?$/.test(v));
  }
  function host(url) { try { return new URL(url).hostname; } catch (e) { return ""; } }

  var COLORS = ["#ff453a", "#ff9f0a", "#30d158", "#0a84ff", "#5e5ce6", "#bf5af2", "#ff375f", "#64d2ff"];
  function letterIcon(name) {
    var e = el("div", "letter", (name.trim()[0] || "?").toUpperCase());
    var sum = 0;
    for (var i = 0; i < name.length; i++) sum += name.charCodeAt(i);
    e.style.background = COLORS[sum % COLORS.length];
    return e;
  }
  function siteIcon(name, url, size) {
    var h = host(url);
    if (!state.icons || !h) return letterIcon(name);
    var img = el("img");
    img.alt = "";
    img.referrerPolicy = "no-referrer";
    img.src = "https://www.google.com/s2/favicons?sz=" + (size || 128) + "&domain=" + encodeURIComponent(h);
    img.onerror = function () { if (img.parentNode) img.parentNode.replaceChild(letterIcon(name), img); };
    return img;
  }

  // ---------------------------------------------------------------- look

  function bgUrl(id) {
    if (id === "custom") return customBg() || "backgrounds/obsidian.jpg";
    return "backgrounds/" + id + ".jpg";
  }
  function applyLook(bgId) {
    $("bg").style.backgroundImage = "url(\"" + bgUrl(bgId || state.bg) + "\")";
    var a = state.dim / 100;
    $("shade").style.background = "radial-gradient(ellipse at center, rgba(0,0,0," + (a * 0.5) +
      ") 0%, rgba(0,0,0," + Math.min(0.9, a + 0.2) + ") 100%)";
    document.documentElement.style.setProperty("--accent", state.accent);
  }

  function applyTexts() {
    document.documentElement.lang = lang();
    document.querySelectorAll("[data-i18n]").forEach(function (n) { n.textContent = t(n.getAttribute("data-i18n")); });
    $("q").placeholder = t("searchWith", { engine: ENGINES[state.engine].name });
    $("q").setAttribute("aria-label", t("search"));
    $("gear").title = t("settingsLabel");
    $("gear").setAttribute("aria-label", t("settingsLabel"));
    $("sLang").options[0].textContent = t("auto");
  }

  // ---------------------------------------------------------------- clock

  function tick() {
    $("mark").hidden = !state.showLogo;
    $("clock").hidden = $("greeting").hidden = !state.showClock;
    if (!state.showClock) return;
    var d = new Date(), h = d.getHours();
    $("clock").textContent = new Intl.DateTimeFormat(lang() === "de" ? "de-DE" : undefined, { hour: "numeric", minute: "2-digit" }).format(d);
    var g = h < 5 ? t("night") : h < 11 ? t("morning") : h < 18 ? t("day") : h < 22 ? t("evening") : t("night");
    $("greeting").textContent = state.name ? g + ", " + state.name : g;
  }

  // ---------------------------------------------------------------- favorites

  var dragFrom = null;

  function renderFavs() {
    var box = $("favs");
    box.textContent = "";
    box.hidden = !state.showFavs;
    if (!state.showFavs) return;
    state.favorites.forEach(function (f, i) {
      var item = el("div", "fav");
      item.draggable = true;

      var a = el("a");
      a.href = f.url;
      a.draggable = false;
      var tile = el("div", "tile");
      tile.appendChild(siteIcon(f.name, f.url));
      a.appendChild(tile);
      a.appendChild(el("div", "label", f.name));

      var edit = el("button", "edit", "✎");
      edit.type = "button";
      edit.title = t("edit");
      edit.setAttribute("aria-label", t("edit") + ": " + f.name);
      edit.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); openFav(i); });

      item.appendChild(a);
      item.appendChild(edit);

      item.addEventListener("dragstart", function (e) {
        dragFrom = i;
        item.classList.add("dragging");
        try { e.dataTransfer.setData("text/plain", String(i)); e.dataTransfer.effectAllowed = "move"; } catch (err) {}
      });
      item.addEventListener("dragend", function () { item.classList.remove("dragging"); dragFrom = null; });
      item.addEventListener("dragover", function (e) { if (dragFrom !== null) { e.preventDefault(); item.classList.add("over"); } });
      item.addEventListener("dragleave", function () { item.classList.remove("over"); });
      item.addEventListener("drop", function (e) {
        e.preventDefault();
        item.classList.remove("over");
        if (dragFrom === null || dragFrom === i) return;
        state.favorites.splice(i, 0, state.favorites.splice(dragFrom, 1)[0]);
        save();
        renderFavs();
      });
      box.appendChild(item);
    });

    var add = el("button", "fav add");
    add.type = "button";
    add.style.background = "none";
    add.style.border = "0";
    add.appendChild(el("div", "tile", "+"));
    add.appendChild(el("div", "label", t("add")));
    add.addEventListener("click", function () { openFav(-1); });
    box.appendChild(add);
  }

  var editing = -1;
  function openFav(i) {
    editing = i;
    var f = i >= 0 ? state.favorites[i] : { name: "", url: "" };
    $("favTitle").textContent = i >= 0 ? t("editFav") : t("addFav");
    $("favName").value = f.name;
    $("favUrl").value = f.url.replace(/^https:\/\//, "").replace(/\/$/, "");
    $("favDelete").hidden = i < 0;
    show("favDialog");
    setTimeout(function () { $("favName").focus(); }, 30);
  }
  $("favForm").addEventListener("submit", function (e) {
    e.preventDefault();
    var name = $("favName").value.trim(), url = safeUrl($("favUrl").value);
    if (!name) return;
    if (!url) { alert(t("invalidUrl")); return; }
    var f = { name: name.slice(0, 40), url: url };
    if (editing >= 0) state.favorites[editing] = f; else state.favorites.push(f);
    save(); renderFavs(); hide("favDialog");
  });
  $("favDelete").addEventListener("click", function () {
    if (editing < 0 || !confirm(t("confirmDelete", { name: state.favorites[editing].name }))) return;
    state.favorites.splice(editing, 1);
    save(); renderFavs(); hide("favDialog");
  });
  $("favCancel").addEventListener("click", function () { hide("favDialog"); });

  // ---------------------------------------------------------------- search

  $("search").addEventListener("submit", function (e) {
    e.preventDefault();
    var v = $("q").value.trim();
    if (!v) return;
    var direct = looksLikeUrl(v) && safeUrl(v);
    location.href = direct || ENGINES[state.engine].url + encodeURIComponent(v);
  });

  // ---------------------------------------------------------------- dialogs

  function show(id) { $(id).hidden = false; }
  function hide(id) { $(id).hidden = true; }
  function anyDialog() { return ["favDialog", "setDialog", "onboarding"].some(function (id) { return !$(id).hidden; }); }

  ["favDialog", "setDialog"].forEach(function (id) {
    $(id).addEventListener("mousedown", function (e) { if (e.target === this) hide(id); });
  });

  document.addEventListener("keydown", function (e) {
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (e.key === "Escape") { hide("favDialog"); hide("setDialog"); return; }
    if (anyDialog() || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "/" && !typing) { e.preventDefault(); $("q").focus(); return; }
    if (!typing && /^[1-9]$/.test(e.key)) {
      var f = state.favorites[Number(e.key) - 1];
      if (f) location.href = f.url;
    }
  });

  // ---------------------------------------------------------------- backgrounds (shared by settings + onboarding)

  // Shrinks a chosen photo and stores it in the browser.
  function useOwnImage(done) {
    var input = $("bgFile");
    input.onchange = function () {
      var file = input.files && input.files[0];
      input.value = "";
      if (!file) return;
      var reader = new FileReader();
      reader.onload = function () {
        var img = new Image();
        img.onload = function () {
          var scale = Math.min(1, 2560 / Math.max(img.width, img.height));
          var c = document.createElement("canvas");
          c.width = Math.round(img.width * scale);
          c.height = Math.round(img.height * scale);
          c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
          var q = 0.85, data = c.toDataURL("image/jpeg", q);
          while (data.length > 4000000 && q > 0.4) { q -= 0.1; data = c.toDataURL("image/jpeg", q); }
          try { localStorage.setItem(BG_KEY, data); done(); }
          catch (e) { alert(t("imageTooBig")); }
        };
        img.src = reader.result;
      };
      reader.readAsDataURL(file);
    };
    input.click();
  }

  function renderBgPicker(box, current, onPick) {
    box.textContent = "";
    var list = BACKGROUNDS.slice();
    if (customBg()) list.push({ id: "custom", name: t("ownImage").replace(" …", "") });
    list.forEach(function (b) {
      var btn = el("button");
      btn.type = "button";
      btn.className = b.id === current ? "on" : "";
      btn.style.backgroundImage = "url(\"" + bgUrl(b.id) + "\")";
      btn.appendChild(el("span", null, b.name));
      btn.addEventListener("click", function () { onPick(b.id); });
      box.appendChild(btn);
    });
    var up = el("button", "upload", t("ownImage"));
    up.type = "button";
    up.addEventListener("click", function () { useOwnImage(function () { onPick("custom"); }); });
    box.appendChild(up);
  }

  // ---------------------------------------------------------------- settings

  Object.keys(ENGINES).forEach(function (k) {
    var o = el("option", null, ENGINES[k].name);
    o.value = k;
    $("sEngine").appendChild(o);
  });

  function renderSettings() {
    $("sLang").value = state.lang;
    $("sName").value = state.name;
    $("sClock").checked = state.showClock;
    $("sLogo").checked = state.showLogo;
    $("sEngine").value = state.engine;
    $("sDim").value = state.dim;
    $("sIcons").checked = state.icons;
    $("sShowFavs").checked = state.showFavs;
    $("sShowRecent").checked = state.showRecent;
    $("sWeather").checked = state.weatherOn;
    $("sCity").value = state.weatherCity;
    renderBgPicker($("sBgs"), state.bg, function (id) { state.bg = id; save(); applyLook(); renderSettings(); });
    var sw = $("sAccent");
    sw.textContent = "";
    ACCENTS.forEach(function (c) {
      var b = el("button");
      b.type = "button";
      b.style.background = c;
      b.className = c === state.accent ? "on" : "";
      b.setAttribute("aria-label", c);
      b.addEventListener("click", function () { state.accent = c; save(); applyLook(); renderSettings(); });
      sw.appendChild(b);
    });
  }

  $("gear").addEventListener("click", function () { openSettings(); });
  $("sClose").addEventListener("click", function () { hide("setDialog"); });

  // Tabs inside the settings (the last one used is remembered).
  var PANE_KEY = "rook.settingsPane";
  function showPane(name) {
    document.querySelectorAll("#sTabs button").forEach(function (b) {
      var on = b.getAttribute("data-pane") === name;
      b.classList.toggle("on", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll(".pane").forEach(function (p) { p.classList.toggle("on", p.getAttribute("data-pane") === name); });
    try { localStorage.setItem(PANE_KEY, name); } catch (e) {}
    if (name === "browser" || name === "privacy") loadBrowserSettings();
  }
  document.querySelectorAll("#sTabs button").forEach(function (b) {
    b.addEventListener("click", function () { showPane(b.getAttribute("data-pane")); });
  });

  function openSettings(pane) {
    renderSettings();
    var last = null;
    try { last = localStorage.getItem(PANE_KEY); } catch (e) {}
    showPane(pane || last || "look");
    show("setDialog");
  }

  // ---------------------------------------------------------------- browser settings (inside the app)

  function api(path) {
    return fetch("api/" + path, { cache: "no-store" }).then(function (r) { return r.json(); });
  }

  // A row with name, short description and a switch for one filter list (settings and onboarding).
  function listSwitch(id, on, onChange) {
    var key = "list" + id.charAt(0).toUpperCase() + id.slice(1);
    var item = el("label", "item");
    var txt = el("span", "item-text", t(key));
    txt.appendChild(el("small", null, t(key + "Desc")));
    item.appendChild(txt);
    var sw = el("input", "switch");
    sw.type = "checkbox";
    sw.checked = on;
    sw.addEventListener("change", function () { onChange(sw.checked); });
    item.appendChild(sw);
    return item;
  }

  function loadBrowserSettings() {
    if (!inApp) return;
    api("settings.json").then(showBrowserSettings).catch(function () {});
  }

  function showBrowserSettings(s) {
    if (!s || !s.app) return;
    $("sFolder").textContent = s.downloadFolder;
    $("sFolder").title = s.downloadFolder;
    $("sFolderReset").hidden = s.downloadFolderIsDefault;
    $("sAsk").checked = s.askWhereToSave;
    $("sRestore").checked = s.restoreSession;
    $("sDefaultStatus").textContent = s.isDefaultBrowser ? t("isDefault") : t("notDefault");
    $("sMakeDefault").hidden = s.isDefaultBrowser;
    $("sBlocker").checked = s.blocker.enabled;
    $("sBlockerStatus").textContent = s.blocker.status;
    $("sHistoryInfo").textContent = t("historyInfo", { n: s.historyCount });

    // One row per site: name (and details) on the left, a text button on the right.
    function row(title, detail, label, onClick) {
      var item = el("div", "item");
      var txt = el("span", "item-text", title);
      if (detail) txt.appendChild(el("small", null, detail));
      item.appendChild(txt);
      var b = el("button", "link", label);
      b.type = "button";
      b.addEventListener("click", onClick);
      item.appendChild(b);
      return item;
    }

    // One switch per filter list, between the main switch and the status row.
    var group = $("sBlockerGroup");
    Array.prototype.slice.call(group.querySelectorAll(".list-item")).forEach(function (n) { n.remove(); });
    (s.blocker.lists || []).forEach(function (l) {
      var item = listSwitch(l.id, l.enabled, function (on) { api("set?key=list." + l.id + "&value=" + on).then(showBrowserSettings); });
      item.classList.add("list-item");
      item.querySelector("input").disabled = !s.blocker.enabled;
      group.insertBefore(item, $("sBlockerStatusRow"));
    });

    var ex = $("sExceptions");
    ex.textContent = "";
    if (!s.blocker.exceptions.length) ex.appendChild(el("div", "item empty", t("noExceptions")));
    s.blocker.exceptions.forEach(function (site) {
      ex.appendChild(row(site, "", t("remove"), function () {
        api("blocker-remove-exception?site=" + encodeURIComponent(site)).then(showBrowserSettings);
      }));
    });

    var sites = $("sSites");
    sites.textContent = "";
    if (!s.sites.length) sites.appendChild(el("div", "item empty", t("noSitePermissions")));
    s.sites.forEach(function (x) {
      var parts = [];
      if (x.camera) parts.push(t("camera") + " " + t(x.camera === "allow" ? "allowed" : "denied"));
      if (x.microphone) parts.push(t("microphone") + " " + t(x.microphone === "allow" ? "allowed" : "denied"));
      if (x.zoom) parts.push(t("zoom") + " " + x.zoom + " %");
      sites.appendChild(row(x.site, parts.join(", "), t("reset"), function () {
        api("forget-site?site=" + encodeURIComponent(x.site)).then(showBrowserSettings);
      }));
    });
  }

  function setting(key, value) { api("set?key=" + key + "&value=" + value).then(showBrowserSettings); }
  $("sAsk").addEventListener("change", function () { setting("askWhereToSave", this.checked); });
  $("sRestore").addEventListener("change", function () { setting("restoreSession", this.checked); });
  $("sBlocker").addEventListener("change", function () { setting("blocker", this.checked); });
  $("sFolderChange").addEventListener("click", function () { api("choose-download-folder").then(showBrowserSettings); });
  $("sFolderShow").addEventListener("click", function () { api("show-download-folder"); });
  $("sFolderReset").addEventListener("click", function () { api("reset-download-folder").then(showBrowserSettings); });
  $("sMakeDefault").addEventListener("click", function () { api("make-default").then(showBrowserSettings); });
  $("sImportBookmarks").addEventListener("click", function () { api("import-bookmarks"); });
  $("sBlockerUpdate").addEventListener("click", function () {
    $("sBlockerStatus").textContent = t("updating");
    api("blocker-update").then(showBrowserSettings);
  });
  $("sClearHistory").addEventListener("click", function () {
    if (!confirm(t("confirmClearHistory"))) return;
    api("clear-history").then(function () {
      renderRecent([]);
      $("sHistoryInfo").textContent = t("historyCleared");
    });
  });
  $("sClearData").addEventListener("click", function () {
    if (!confirm(t("confirmClearData"))) return;
    api("clear-website-data").then(function () { alert(t("dataCleared")); });
  });
  $("sShowFavs").addEventListener("change", function () { state.showFavs = this.checked; save(); renderFavs(); });
  $("sShowRecent").addEventListener("change", function () { state.showRecent = this.checked; save(); renderRecent(lastRecent); });
  $("sLang").addEventListener("change", function () { state.lang = this.value; save(); refresh(); renderSettings(); });
  $("sName").addEventListener("input", function () { state.name = this.value.trim().slice(0, 30); save(); tick(); });
  $("sClock").addEventListener("change", function () { state.showClock = this.checked; save(); tick(); });
  $("sLogo").addEventListener("change", function () { state.showLogo = this.checked; save(); tick(); });
  $("sEngine").addEventListener("change", function () {
    state.engine = this.value; state.engineChangedAt = Date.now(); save(); applyTexts();
    if (inApp) api("set?key=engine&value=" + encodeURIComponent(this.value));
  });
  $("sWeather").addEventListener("change", function () { state.weatherOn = this.checked; save(); renderWeather(true); });
  $("sCity").addEventListener("change", function () { state.weatherCity = this.value.trim().slice(0, 60); save(); renderWeather(true); });

  // ---------------------------------------------------------------- weather (opt-in, open-meteo.com)

  var WEATHER_KEY = "rook.weather";
  var WEATHER_ICONS = [[0, "☀️"], [2, "🌤️"], [3, "☁️"], [48, "🌫️"], [67, "🌧️"], [77, "🌨️"], [82, "🌦️"], [99, "⛈️"]];
  function weatherIcon(code) {
    for (var i = 0; i < WEATHER_ICONS.length; i++) if (code <= WEATHER_ICONS[i][0]) return WEATHER_ICONS[i][1];
    return "🌡️";
  }

  function renderWeather(force) {
    var box = $("weather");
    if (!state.weatherOn || !state.weatherCity) { box.hidden = true; return; }
    var cached = null;
    try { cached = JSON.parse(localStorage.getItem(WEATHER_KEY) || "null"); } catch (e) {}
    var fresh = cached && cached.city === state.weatherCity && Date.now() - cached.time < 30 * 60 * 1000;
    if (fresh && !force) { showWeather(cached); return; }
    var city = state.weatherCity;
    fetch("https://geocoding-api.open-meteo.com/v1/search?count=1&language=" + lang() + "&name=" + encodeURIComponent(city))
      .then(function (r) { return r.json(); })
      .then(function (g) {
        var place = g.results && g.results[0];
        if (!place) throw new Error("not found");
        return fetch("https://api.open-meteo.com/v1/forecast?current=temperature_2m,weather_code&latitude=" +
          place.latitude.toFixed(2) + "&longitude=" + place.longitude.toFixed(2))
          .then(function (r) { return r.json(); })
          .then(function (w) {
            var data = { city: city, name: place.name, temp: Math.round(w.current.temperature_2m),
                         icon: weatherIcon(w.current.weather_code), time: Date.now() };
            try { localStorage.setItem(WEATHER_KEY, JSON.stringify(data)); } catch (e) {}
            showWeather(data);
          });
      })
      .catch(function () { box.hidden = false; box.textContent = t("weatherError"); });
  }

  function showWeather(d) {
    var box = $("weather");
    box.hidden = false;
    box.textContent = d.icon + " " + d.temp + "° · " + d.name;
  }

  // ---------------------------------------------------------------- inside the Rook browser app

  var inApp = location.protocol === "rook:";

  /// Exchanges data with the browser: favorites added with ⌘D or imported, the search engine
  /// chosen in the browser settings, and recently visited pages (only shown inside the app).
  function syncWithBrowser() {
    if (!inApp) return;
    fetch("api/native.json", { cache: "no-store" }).then(function (r) { return r.json(); }).then(function (n) {
      var changed = false;
      if (ENGINES[n.engine] && n.engineChangedAt > (state.engineChangedAt || 0) && n.engine !== state.engine) {
        state.engine = n.engine;
        state.engineChangedAt = n.engineChangedAt;
        changed = true;
      }
      var pending = Array.isArray(n.pendingFavorites) ? n.pendingFavorites : [];
      pending.forEach(function (f) {
        var url = f && safeUrl(f.url);
        if (url && typeof f.name === "string" && state.favorites.length < 60 &&
            !state.favorites.some(function (x) { return x.url === url; })) {
          state.favorites.push({ name: f.name.trim().slice(0, 40) || host(url), url: url });
          changed = true;
        }
      });
      if (pending.length) fetch("api/favorites-taken?count=" + pending.length);
      if (changed) { save(); applyTexts(); renderFavs(); }
      fetch("api/favorites-known?list=" + encodeURIComponent(JSON.stringify(state.favorites)));
      renderRecent(Array.isArray(n.recent) ? n.recent : []);
    }).catch(function () {});
  }

  var lastRecent = [];
  function renderRecent(list) {
    lastRecent = list;
    var box = $("recent");
    box.textContent = "";
    var items = state.showRecent ? list.filter(function (r) { return r && safeUrl(r.url); }).slice(0, 6) : [];
    if (!items.length) { box.hidden = true; return; }
    box.hidden = false;
    box.appendChild(el("div", "recent-title", t("recent")));
    var row = el("div", "recent-row");
    items.forEach(function (r) {
      var a = el("a", "chip");
      a.href = safeUrl(r.url);
      a.title = r.url;
      a.appendChild(siteIcon(r.title || host(r.url), safeUrl(r.url), 32));
      a.appendChild(el("span", null, r.title || host(r.url)));
      row.appendChild(a);
    });
    box.appendChild(row);
  }
  $("sDim").addEventListener("input", function () { state.dim = Number(this.value); save(); applyLook(); });
  $("sIcons").addEventListener("change", function () { state.icons = this.checked; save(); renderFavs(); });

  $("sExport").addEventListener("click", function () {
    var blob = new Blob([JSON.stringify(state, null, 2)], { type: "application/json" });
    var a = el("a");
    a.href = URL.createObjectURL(blob);
    a.download = "rook-backup.json";
    document.body.appendChild(a);
    a.click();
    a.remove();
  });
  $("sImport").addEventListener("click", function () { $("sImportFile").click(); });
  $("sImportFile").addEventListener("change", function () {
    var file = this.files && this.files[0];
    this.value = "";
    if (!file) return;
    var reader = new FileReader();
    reader.onload = function () {
      try {
        var data = JSON.parse(reader.result);
        if (!Array.isArray(data.favorites)) throw new Error("no favorites");
        state = sanitize(data);
        state.onboarded = true;
        save(); refresh(); renderSettings();
      } catch (e) { alert(t("importFailed")); }
    };
    reader.readAsText(file);
  });
  $("sRestart").addEventListener("click", function () { hide("setDialog"); startOnboarding(true); });
  $("sReset").addEventListener("click", function () {
    if (!confirm(t("confirmReset"))) return;
    try { localStorage.removeItem(KEY); localStorage.removeItem(BG_KEY); } catch (e) {}
    state = defaults();
    hide("setDialog");
    refresh();
    startOnboarding(true);
  });

  // ---------------------------------------------------------------- onboarding

  var ob = null;
  // The ad blocker only exists inside the Rook app.
  var STEPS = inApp ? ["welcome", "engine", "blocker", "background", "favorites"] : ["welcome", "engine", "background", "favorites"];
  var BLOCKER_LISTS = ["easylist", "easyprivacy", "easylistgermany"];

  function startOnboarding(withIntro) {
    var picks = {};
    state.favorites.forEach(function (f) { picks[f.name] = f.url; });
    var lists = {};
    BLOCKER_LISTS.forEach(function (id) { lists[id] = true; });
    ob = { step: 0, name: state.name, engine: state.engine, bg: state.bg, picks: picks, lists: lists };
    $("home").hidden = true;
    $("gear").hidden = true;
    if (inApp) {
      api("settings.json").then(function (s) {
        (s.blocker.lists || []).forEach(function (l) { if (ob) ob.lists[l.id] = s.blocker.enabled && l.enabled; });
        if (ob && STEPS[ob.step] === "blocker") renderStep();
      }).catch(function () {});
    }
    if (withIntro) playIntro(); else openSteps();
  }

  function openSteps() {
    show("onboarding");
    renderStep();
  }

  // First start: the raven, the name and two sentences, then the setup.
  function playIntro() {
    var intro = $("intro");
    $("introText").textContent = t(inApp ? "introApp" : "introWeb");
    intro.classList.remove("leaving", "skip");
    intro.hidden = false;
    // A click anywhere before the button appears shows everything at once.
    intro.onclick = function (e) { if (e.target.id !== "introGo") intro.classList.add("skip"); };
    $("introGo").onclick = function () {
      intro.classList.add("leaving");
      openSteps();
      setTimeout(function () { intro.hidden = true; }, 500);
    };
    setTimeout(function () { $("introGo").focus(); }, 2400);
  }

  function renderStep() {
    var step = STEPS[ob.step], body = $("obBody");
    body.textContent = "";

    var dots = $("obDots");
    dots.textContent = "";
    STEPS.forEach(function (s, i) { dots.appendChild(el("span", i <= ob.step ? "on" : "")); });

    if (step === "welcome") {
      var head = el("div", "ob-head");
      var logo = el("img", "logo");
      logo.src = "assets/logo.png";
      logo.alt = "";
      head.appendChild(logo);
      head.appendChild(el("h1", null, t("welcomeTitle")));
      body.appendChild(head);
      body.appendChild(el("p", "ob-sub", t("welcomeText")));
      var lbl = el("label", null, t("whatName"));
      lbl.htmlFor = "obName";
      var inp = el("input");
      inp.type = "text";
      inp.id = "obName";
      inp.placeholder = t("namePlaceholder");
      inp.maxLength = 30;
      inp.value = ob.name;
      inp.addEventListener("input", function () { ob.name = inp.value.trim(); });
      inp.addEventListener("keydown", function (e) { if (e.key === "Enter") next(); });
      body.appendChild(lbl);
      body.appendChild(inp);
      setTimeout(function () { inp.focus(); }, 30);
    }

    if (step === "engine") {
      body.appendChild(el("h2", null, t("engineTitle")));
      body.appendChild(el("p", "ob-sub", t("engineText")));
      var list = el("div", "engines");
      list.setAttribute("role", "radiogroup");
      Object.keys(ENGINES).forEach(function (k) {
        var e = ENGINES[k], on = ob.engine === k;
        var row = el("button", "engine");
        row.type = "button";
        row.setAttribute("role", "radio");
        row.setAttribute("aria-checked", on ? "true" : "false");
        row.appendChild(siteIcon(e.name, e.url, 64));
        var txt = el("div", "engine-text");
        txt.appendChild(el("div", "engine-name", e.name));
        txt.appendChild(el("div", "engine-desc", t(e.desc)));
        row.appendChild(txt);
        row.appendChild(el("span", "tick", on ? "✓" : ""));
        row.addEventListener("click", function () { ob.engine = k; renderStep(); });
        list.appendChild(row);
      });
      body.appendChild(list);
    }

    if (step === "blocker") {
      body.appendChild(el("h2", null, t("blockerTitle")));
      body.appendChild(el("p", "ob-sub", t("blockerText")));
      var group = el("div", "group");
      BLOCKER_LISTS.forEach(function (id) {
        group.appendChild(listSwitch(id, ob.lists[id], function (on) { ob.lists[id] = on; }));
      });
      body.appendChild(group);
      body.appendChild(el("p", "ob-hint", t("blockerHint")));
    }

    if (step === "background") {
      body.appendChild(el("h2", null, t("bgTitle")));
      body.appendChild(el("p", "ob-sub", t("bgText")));
      var bgs = el("div", "bgs");
      renderBgPicker(bgs, ob.bg, function (id) { ob.bg = id; applyLook(id); renderStep(); });
      body.appendChild(bgs);
    }

    if (step === "favorites") {
      body.appendChild(el("h2", null, t("favTitle")));
      body.appendChild(el("p", "ob-sub", t("favText")));
      var picks = el("div", "picks");
      presets(lang()).forEach(function (p) {
        var on = Object.prototype.hasOwnProperty.call(ob.picks, p.name);
        var b = el("button", "pick" + (on ? " on" : ""));
        b.type = "button";
        b.setAttribute("aria-pressed", on ? "true" : "false");
        b.appendChild(siteIcon(p.name, p.url, 64));
        b.appendChild(el("span", null, p.name));
        b.addEventListener("click", function () {
          if (on) delete ob.picks[p.name]; else ob.picks[p.name] = p.url;
          renderStep();
        });
        picks.appendChild(b);
      });
      body.appendChild(picks);
    }

    $("obSkip").textContent = t("skip");
    $("obBack").textContent = t("back");
    $("obBack").hidden = ob.step === 0;
    $("obNext").textContent = ob.step === STEPS.length - 1 ? t("letsGo") : t("next");
  }

  function next() {
    if (ob.step < STEPS.length - 1) { ob.step++; renderStep(); } else finishOnboarding(true);
  }
  function finishOnboarding(apply) {
    if (apply) {
      state.name = ob.name.slice(0, 30);
      state.engine = ob.engine;
      state.bg = ob.bg;
      // Keep the order of the preset list, then any own favorites that were already there.
      var chosen = presets(lang()).filter(function (p) { return ob.picks[p.name]; });
      Object.keys(ob.picks).forEach(function (n) {
        if (!chosen.some(function (c) { return c.name === n; })) chosen.push({ name: n, url: ob.picks[n] });
      });
      state.favorites = chosen;
      if (inApp) {
        var any = BLOCKER_LISTS.some(function (id) { return ob.lists[id]; });
        BLOCKER_LISTS.forEach(function (id) { if (any) api("set?key=list." + id + "&value=" + ob.lists[id]); });
        api("set?key=blocker&value=" + any);
      }
    }
    // Tells the app that the setup is done (it then offers to become the default browser once).
    if (inApp) api("onboarding-done").catch(function () {});
    state.onboarded = true;
    save();
    ob = null;
    hide("onboarding");
    refresh();
    $("q").focus();
  }

  $("obNext").addEventListener("click", next);
  $("obBack").addEventListener("click", function () { if (ob.step > 0) { ob.step--; renderStep(); } });
  $("obSkip").addEventListener("click", function () { finishOnboarding(false); });

  // ---------------------------------------------------------------- start

  function refresh() {
    applyTexts();
    applyLook();
    tick();
    renderFavs();
    renderWeather(false);
    syncWithBrowser();
    $("home").hidden = false;
    $("gear").hidden = false;
  }

  document.body.classList.toggle("in-app", inApp);
  if (state.onboarded) refresh(); else { applyTexts(); applyLook(); startOnboarding(true); }
  setInterval(tick, 10000);

  // ⌘, in the Rook app opens the start page with #settings.
  function settingsFromAddress() {
    if (location.hash === "#settings" && state.onboarded) {
      openSettings();
      history.replaceState(null, "", location.pathname);
    }
  }
  settingsFromAddress();
  window.addEventListener("hashchange", settingsFromAddress);
})();

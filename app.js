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
      showClock: "Show time and greeting", search: "Search", engine: "Search engine", look: "Look",
      dim: "Darken background", accent: "Accent color", privacy: "Privacy",
      loadIcons: "Load website logos",
      loadIconsHint: "Logos are fetched from Google’s favicon service, which sees which sites are on your page. Turn this off to show letters instead.",
      backup: "Backup", export: "Export", import: "Import …", restartOnboarding: "Show welcome again",
      resetAll: "Reset everything", confirmReset: "Reset Rook? Your favorites and settings will be removed.",
      importFailed: "This file is not a valid Rook backup.", imageTooBig: "This image is too large. Please choose a smaller one.",
      editHint: "Tip: hover a favorite and click ✎ to edit it, drag to reorder. Press / to search, 1–9 to open a favorite.",
      ownImage: "Own image …", skip: "Skip", back: "Back", next: "Next", letsGo: "Let’s go",
      welcomeTitle: "Welcome to Rook",
      welcomeText: "Your new tab page – calm, beautiful and private. Everything stays in this browser. Set it up in four quick steps.",
      whatName: "What should we call you? (optional)",
      engineTitle: "Choose your search engine", engineText: "You can change this anytime in the settings.",
      bgTitle: "Pick a background", bgText: "Or use one of your own photos.",
      favTitle: "Your favorites", favText: "Tap to select the sites you use most. You can add your own later.",
      settingsLabel: "Settings", privateEngine: "private", treesEngine: "plants trees"
    },
    de: {
      searchWith: "Mit {engine} suchen oder Adresse eingeben",
      morning: "Guten Morgen", day: "Guten Tag", evening: "Guten Abend", night: "Gute Nacht",
      add: "Hinzufügen", edit: "Bearbeiten", addFav: "Favorit hinzufügen", editFav: "Favorit bearbeiten",
      name: "Name", address: "Adresse", delete: "Löschen", cancel: "Abbrechen", save: "Sichern", done: "Fertig",
      confirmDelete: "„{name}“ löschen?", invalidUrl: "Bitte eine gültige Webadresse eingeben (http oder https).",
      settings: "Einstellungen", general: "Allgemein", language: "Sprache", auto: "Automatisch", yourName: "Dein Name",
      showClock: "Uhrzeit und Begrüßung anzeigen", search: "Suche", engine: "Suchmaschine", look: "Aussehen",
      dim: "Hintergrund abdunkeln", accent: "Akzentfarbe", privacy: "Datenschutz",
      loadIcons: "Logos der Websites laden",
      loadIconsHint: "Die Logos kommen vom Favicon-Dienst von Google. Google sieht dadurch, welche Seiten auf deiner Startseite sind. Ausgeschaltet erscheinen stattdessen Buchstaben.",
      backup: "Sicherung", export: "Exportieren", import: "Importieren …", restartOnboarding: "Begrüßung erneut zeigen",
      resetAll: "Alles zurücksetzen", confirmReset: "Rook zurücksetzen? Deine Favoriten und Einstellungen werden gelöscht.",
      importFailed: "Diese Datei ist keine gültige Rook-Sicherung.", imageTooBig: "Das Bild ist zu groß. Bitte ein kleineres wählen.",
      editHint: "Tipp: Mit der Maus über einen Favoriten fahren und auf ✎ klicken, zum Umsortieren ziehen. / springt in die Suche, 1–9 öffnet Favoriten.",
      ownImage: "Eigenes Bild …", skip: "Überspringen", back: "Zurück", next: "Weiter", letsGo: "Los geht’s",
      welcomeTitle: "Willkommen bei Rook",
      welcomeText: "Deine neue Startseite – ruhig, schön und privat. Alles bleibt in diesem Browser. In vier kurzen Schritten eingerichtet.",
      whatName: "Wie sollen wir dich nennen? (optional)",
      engineTitle: "Wähle deine Suchmaschine", engineText: "Das kannst du jederzeit in den Einstellungen ändern.",
      bgTitle: "Such dir einen Hintergrund aus", bgText: "Oder nimm ein eigenes Foto.",
      favTitle: "Deine Favoriten", favText: "Tippe die Seiten an, die du am meisten nutzt. Eigene kannst du später ergänzen.",
      settingsLabel: "Einstellungen", privateEngine: "privat", treesEngine: "pflanzt Bäume"
    }
  };

  // ---------------------------------------------------------------- data

  var ENGINES = {
    google: { name: "Google", url: "https://www.google.com/search?q=" },
    duckduckgo: { name: "DuckDuckGo", url: "https://duckduckgo.com/?q=", tag: "privateEngine" },
    startpage: { name: "Startpage", url: "https://www.startpage.com/do/search?q=", tag: "privateEngine" },
    ecosia: { name: "Ecosia", url: "https://www.ecosia.org/search?q=", tag: "treesEngine" },
    bing: { name: "Bing", url: "https://www.bing.com/search?q=" },
    brave: { name: "Brave Search", url: "https://search.brave.com/search?q=", tag: "privateEngine" }
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
      version: 1, onboarded: false, lang: "auto", name: "", showClock: true,
      engine: "google", bg: "obsidian", dim: 30, accent: ACCENTS[0], icons: true,
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
    s.engine = ENGINES[raw.engine] ? raw.engine : d.engine;
    s.bg = raw.bg === "custom" || BACKGROUNDS.some(function (b) { return b.id === raw.bg; }) ? raw.bg : d.bg;
    s.dim = typeof raw.dim === "number" && raw.dim >= 0 && raw.dim <= 80 ? raw.dim : d.dim;
    s.accent = /^#[0-9a-f]{6}$/i.test(raw.accent) ? raw.accent : d.accent;
    s.icons = typeof raw.icons === "boolean" ? raw.icons : d.icons;
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
    $("sEngine").value = state.engine;
    $("sDim").value = state.dim;
    $("sIcons").checked = state.icons;
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

  $("gear").addEventListener("click", function () { renderSettings(); show("setDialog"); });
  $("sClose").addEventListener("click", function () { hide("setDialog"); });
  $("sLang").addEventListener("change", function () { state.lang = this.value; save(); refresh(); renderSettings(); });
  $("sName").addEventListener("input", function () { state.name = this.value.trim().slice(0, 30); save(); tick(); });
  $("sClock").addEventListener("change", function () { state.showClock = this.checked; save(); tick(); });
  $("sEngine").addEventListener("change", function () { state.engine = this.value; save(); applyTexts(); });
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
  $("sRestart").addEventListener("click", function () { hide("setDialog"); startOnboarding(); });
  $("sReset").addEventListener("click", function () {
    if (!confirm(t("confirmReset"))) return;
    try { localStorage.removeItem(KEY); localStorage.removeItem(BG_KEY); } catch (e) {}
    state = defaults();
    hide("setDialog");
    refresh();
    startOnboarding();
  });

  // ---------------------------------------------------------------- onboarding

  var ob = null;
  var STEPS = ["welcome", "engine", "background", "favorites"];

  function startOnboarding() {
    var picks = {};
    state.favorites.forEach(function (f) { picks[f.name] = f.url; });
    ob = { step: 0, name: state.name, engine: state.engine, bg: state.bg, picks: picks };
    $("home").hidden = true;
    $("gear").hidden = true;
    show("onboarding");
    renderStep();
  }

  function renderStep() {
    var step = STEPS[ob.step], body = $("obBody");
    body.textContent = "";

    var dots = $("obDots");
    dots.textContent = "";
    STEPS.forEach(function (s, i) { dots.appendChild(el("span", i <= ob.step ? "on" : "")); });

    if (step === "welcome") {
      var logo = el("img", "logo");
      logo.src = "assets/logo.png";
      logo.alt = "";
      body.appendChild(logo);
      body.appendChild(el("h1", null, t("welcomeTitle")));
      body.appendChild(el("p", null, t("welcomeText")));
      var lbl = el("label", null, t("whatName"));
      lbl.htmlFor = "obName";
      var inp = el("input");
      inp.type = "text";
      inp.id = "obName";
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
      body.appendChild(el("p", null, t("engineText")));
      var grid = el("div", "choices");
      Object.keys(ENGINES).forEach(function (k) {
        var e = ENGINES[k], c = el("button", "choice" + (ob.engine === k ? " on" : ""));
        c.type = "button";
        c.appendChild(siteIcon(e.name, e.url, 64));
        var txt = el("div", null, e.name);
        if (e.tag) txt.appendChild(el("small", null, t(e.tag)));
        c.appendChild(txt);
        c.addEventListener("click", function () { ob.engine = k; renderStep(); });
        grid.appendChild(c);
      });
      body.appendChild(grid);
    }

    if (step === "background") {
      body.appendChild(el("h2", null, t("bgTitle")));
      body.appendChild(el("p", null, t("bgText")));
      var bgs = el("div", "bgs");
      renderBgPicker(bgs, ob.bg, function (id) { ob.bg = id; applyLook(id); renderStep(); });
      body.appendChild(bgs);
    }

    if (step === "favorites") {
      body.appendChild(el("h2", null, t("favTitle")));
      body.appendChild(el("p", null, t("favText")));
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
    }
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
    $("home").hidden = false;
    $("gear").hidden = false;
  }

  if (state.onboarded) refresh(); else { applyTexts(); applyLook(); startOnboarding(); }
  setInterval(tick, 10000);
})();

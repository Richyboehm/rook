<p align="center">
  <img src="assets/logo.svg" width="96" height="96" alt="Rook logo">
</p>

<h1 align="center">Rook</h1>

<p align="center">
  A calm, beautiful and private new tab page.<br>
  Glass look, your favorites, your search engine – and nothing else.
</p>

<p align="center">
  <img src="assets/screenshot.png" alt="Rook new tab page with clock, search bar and favorites" width="800">
</p>

## Why Rook?

Most new tab pages are either plain or full of news, ads and tracking. Rook gives you a polished, Apple-style start page while your browser keeps doing what it does best: security, passwords, sync and updates.

- **Beautiful** – dark glass design, large clock with greeting, four hand-made backgrounds or your own photo
- **Private** – no account, no server, no analytics. Everything is stored locally in your browser
- **Fast** – plain HTML, CSS and JavaScript. No framework, no build step, under 100 KB of code
- **Easy** – a short welcome flow sets up your name, search engine, background and favorites
- **Yours** – add, edit and reorder favorites right on the page, choose an accent color, export a backup
- **Bilingual** – English and German, picked automatically from your browser

## Use it

### Option 1: Online (no download)

Open **https://richyboehm.github.io/rook/** and set it as your home and new tab page (see below).

### Option 2: Locally

1. Download this repository (**Code → Download ZIP**) and unzip it somewhere permanent, e.g. your Documents folder.
2. Open `index.html` once in your browser to check it works.
3. Set the file address (e.g. `file:///Users/you/Documents/rook/index.html`) as your home and new tab page.

## Set it as your new tab page

**Safari (Mac)**
Safari → Settings → General:
- *Homepage*: the Rook address
- *New windows open with*: Homepage
- *New tabs open with*: Homepage

**Firefox**
Settings → Home → *Homepage and new windows*: Custom URLs → the Rook address.
Firefox does not allow custom new tab pages by default – use the add-on *New Tab Override* for that.

**Chrome, Edge, Brave**
Settings → On startup → *Open a specific page* → the Rook address.
For new tabs, these browsers require an extension that redirects the new tab page to a URL of your choice.

## Keyboard shortcuts

| Key | Action |
|---|---|
| `/` | Jump to the search bar |
| `1` – `9` | Open favorite 1 to 9 |
| `Esc` | Close dialogs |

## Privacy

- All settings and favorites live in your browser’s `localStorage`. Nothing is sent anywhere.
- Your searches go directly to the search engine you chose.
- Website logos are loaded from Google’s favicon service. You can turn this off under **Settings → Privacy**; Rook then shows colored letters instead.
- Only `http` and `https` links are accepted as favorites, and imported backups are validated.

## Customize

Everything is in three small files:

| File | What’s inside |
|---|---|
| `index.html` | Page structure and dialogs |
| `style.css` | Colors, glass effect, layout |
| `app.js` | Logic, texts (English/German), search engines and suggested favorites |

To add a search engine, extend `ENGINES` in `app.js`. To change the suggested favorites in the welcome flow, edit `presets()`.

## Credits

The backgrounds *Obsidian*, *Aurora*, *Ember* and *Midnight* were generated for Rook and are covered by the same license as the code.

## License

[MIT](LICENSE) – free to use, change and share.

---

### Deutsch

**Rook** ist eine ruhige, schöne und private Startseite für deinen Browser: Uhr mit Begrüßung, große Suchleiste, deine Favoriten und ein Glas-Look im Apple-Stil. Alles wird nur lokal in deinem Browser gespeichert – kein Konto, kein Server, kein Tracking.

**Einrichten in Safari:** Safari → Einstellungen → Allgemein → bei *Homepage* die Rook-Adresse eintragen und bei *Neue Fenster öffnen mit* sowie *Neue Tabs öffnen mit* jeweils **Homepage** wählen.

Beim ersten Öffnen hilft dir eine kurze Begrüßung beim Einrichten. Später findest du alles über das Zahnrad unten rechts.

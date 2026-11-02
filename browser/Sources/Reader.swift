import WebKit

/// The reader view like in Safari: the article of a page, alone, in calm type, without ads, menus
/// and side columns. It is laid over the page (Esc or ⇧⌘R closes it), so going back and the page
/// itself stay untouched. Everything runs in Rook's own script world, the page cannot see it.
enum Reader {
    /// Cheap check after a page loaded: is there an article with enough running text?
    static func checkAvailable(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(findArticle + "; (() => { const a = rookFindArticle(); return !!a && a.score > 1200 })()",
                                   in: nil, in: .defaultClient) { result in
            if case .success(let value) = result { completion(value as? Bool ?? false) } else { completion(false) }
        }
    }

    /// Shows or closes the reader view; the completion gets false when the page has no article.
    static func toggle(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        webView.evaluateJavaScript(findArticle + ";" + toggleScript, in: nil, in: .defaultClient) { result in
            if case .success(let value) = result { completion(value as? String != "none") } else { completion(false) }
        }
    }

    /// Picks the element whose own paragraphs hold the most text (the usual way readers find the article).
    private static let findArticle = #"""
    function rookFindArticle() {
      const scores = new Map();
      for (const p of document.querySelectorAll('p, pre, blockquote')) {
        const text = p.innerText ? p.innerText.trim() : '';
        if (text.length < 40 || p.closest('nav, header, footer, aside, form, [role=navigation], [aria-hidden=true]')) continue;
        const parent = p.parentElement;
        if (!parent) continue;
        scores.set(parent, (scores.get(parent) || 0) + text.length);
        const grand = parent.parentElement;
        if (grand) scores.set(grand, (scores.get(grand) || 0) + text.length / 2);
      }
      let best = null, score = 0;
      for (const [el, s] of scores) if (s > score) { best = el; score = s; }
      if (!best) return null;
      const article = best.closest('article');
      return { element: article && article.innerText.length < best.innerText.length * 3 ? article : best, score };
    }
    """#

    private static let toggleScript = #"""
    (() => {
      const old = document.getElementById('rook-reader');
      if (old) { window.rookReaderShut ? window.rookReaderShut() : old.remove(); return 'off'; }
      const found = rookFindArticle();
      if (!found || found.score < 600) return 'none';

      const content = found.element.cloneNode(true);
      content.querySelectorAll('script, style, link, iframe, form, button, input, select, textarea, nav, aside, footer, noscript, svg, [role=navigation], [aria-hidden=true], [hidden]')
        .forEach(e => e.remove());
      for (const img of content.querySelectorAll('img')) {
        const lazy = img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('data-original');
        if (lazy) img.src = lazy;
        img.removeAttribute('srcset'); img.removeAttribute('sizes'); img.removeAttribute('loading');
        img.removeAttribute('width'); img.removeAttribute('height');
      }
      for (const el of content.querySelectorAll('*')) {
        el.removeAttribute('style'); el.removeAttribute('class'); el.removeAttribute('id');
        for (const a of [...el.attributes]) if (a.name.startsWith('on')) el.removeAttribute(a.name);
      }
      for (const a of content.querySelectorAll('a')) a.target = '_top';

      const h1 = document.querySelector('h1');
      const title = (h1 && h1.innerText.trim()) || document.title;
      for (const h of content.querySelectorAll('h1')) if (h.textContent.trim() === title) h.remove();

      const host = document.createElement('div');
      host.id = 'rook-reader';
      host.dataset.overflow = document.documentElement.style.overflow;
      host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;';
      const root = host.attachShadow({ mode: 'closed' });
      const css = `
        :host { all: initial; }
        .page { position: fixed; inset: 0; overflow-y: auto; background: #f7f5f0; color: #1d1d1f;
                font: 20px/1.6 ui-serif, "New York", Georgia, serif; -webkit-font-smoothing: antialiased; }
        @media (prefers-color-scheme: dark) { .page { background: #1c1c1e; color: #e8e6e3; } a { color: #8ab4ff; } }
        article { max-width: 680px; margin: 0 auto; padding: 64px 28px 120px; }
        .site { font: 600 13px -apple-system, system-ui, sans-serif; letter-spacing: .02em; opacity: .55; text-transform: uppercase; }
        h1 { font: 700 36px/1.2 ui-serif, "New York", Georgia, serif; margin: 10px 0 32px; }
        h2, h3, h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.3; margin: 1.6em 0 .5em; }
        img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
        figure { margin: 1.5em 0; } figcaption { font: 14px/1.4 -apple-system, system-ui, sans-serif; opacity: .6; margin-top: 6px; }
        pre, code { font: 15px ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 14px; border-radius: 8px; background: rgba(127,127,127,.12); }
        blockquote { margin: 1em 0; padding-left: 18px; border-left: 3px solid rgba(127,127,127,.4); opacity: .85; }
        a { color: #0066cc; text-decoration: none; } a:hover { text-decoration: underline; }
        table { border-collapse: collapse; display: block; max-width: 100%; overflow-x: auto; font-size: 16px; } td, th { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; }
        .close { position: fixed; top: 14px; right: 18px; width: 30px; height: 30px; border: 0; border-radius: 15px; cursor: pointer;
                 background: rgba(127,127,127,.18); color: inherit; font: 16px -apple-system, system-ui, sans-serif; }
        .close:hover { background: rgba(127,127,127,.3); }`;
      try {
        const sheet = new CSSStyleSheet(); sheet.replaceSync(css); root.adoptedStyleSheets = [sheet];
      } catch (e) {
        const style = document.createElement('style'); style.textContent = css; root.appendChild(style);
      }
      const page = document.createElement('div'); page.className = 'page';
      const article = document.createElement('article');
      const site = document.createElement('div'); site.className = 'site'; site.textContent = location.hostname.replace(/^www\./, '');
      const heading = document.createElement('h1'); heading.textContent = title;
      const close = document.createElement('button'); close.className = 'close'; close.textContent = '✕'; close.title = 'Leseansicht schließen';
      const shut = () => { host.remove(); document.documentElement.style.overflow = host.dataset.overflow || ''; document.removeEventListener('keydown', onKey, true); };
      const onKey = e => { if (e.key === 'Escape') { e.preventDefault(); shut(); } };
      close.addEventListener('click', shut);
      window.rookReaderShut = shut;
      document.addEventListener('keydown', onKey, true);
      article.append(site, heading, content);
      page.append(close, article);
      root.appendChild(page);
      document.documentElement.style.overflow = 'hidden';
      document.documentElement.appendChild(host);
      page.tabIndex = -1; page.focus();
      return 'on';
    })()
    """#
}

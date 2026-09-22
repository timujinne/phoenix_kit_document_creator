# Claude Review — PR #54

Reviewed the merge diff (`a6beed0..12f1b95`) against LiveView 1.2.12's DOM
patch (`priv/static/phoenix_live_view.js`, `onBeforeElUpdated`), the
thumbnail producer (`GoogleDocsClient.fetch_thumbnail/1`, which stores a
`data:<png|jpeg|webp|gif>;base64,` URI) and the AGENTS.md rule on inline
scripts.

The goal is right and the fixed-frame choice in the second commit is the
better of the two: uneven rows in a card grid look worse than a letterboxed
landscape page. The problem is where the orientation decision is made.

## Findings

### BUG - MEDIUM — the JS-set fit is undone by the next LiveView patch

The handler writes `this.style.objectFit` / `objectPosition`, which reflects
into the element's `style` attribute. When LiveView re-patches the card,
morphdom returns `fromEl` from `onBeforeElUpdated` and syncs its attributes
to the rendered HTML, whose `style` still says `cover; top`. The landscape
page snaps back to the cropped strip, and `onload` does not fire again
because `src` has not changed. `DocumentsLive` re-renders its grid often
(background sync, thumbnails arriving for other cards, PubSub
`:files_changed` resyncs, filter changes), so the fix only held until the
next of those touched the card.

**Fixed.** New `PhoenixKitDocumentCreator.Thumbnail` reads the width and
height from the data URI's image header (PNG IHDR, GIF, the three WebP
variants, JPEG SOFn) and `img_style/1` renders `contain; center` for a
wider-than-tall image. The style is now part of the server render, so
patches keep it. Only the header is decoded (44 base64 chars; up to 16 KB
for JPEG, whose SOF sits after the APPn/DQT/DHT segments), so the cost per
card per render is negligible. Anything unreadable falls back to the old
`cover; top`.

### IMPROVEMENT - MEDIUM — an inline event handler, the pattern AGENTS.md warns against

`onload="…"` is inline script. A host `Content-Security-Policy:
script-src 'self'` blocks it just as it blocks the known-defect `<script>`
in `DocumentsLive`, and AGENTS.md says not to add another. Even when allowed,
the page first paints cropped and then jumps to the fitted layout.

**Fixed** by the same change. Nothing runs on the client, and the first
paint is already correct.

### NITPICK — `landscape_fit_js/0` was public API on a component module

`DocumentsLive` reached it through its blanket `import CreateDocumentModal`.
**Removed** with the handler. `Thumbnail.img_style/1` is the shared helper.

### NITPICK — the tests asserted the JS string, not the behaviour

Both tests used `data:image/png;base64,AA` and matched the handler text, so
they could not tell a portrait page from a landscape one. **Replaced.** The
render tests use a real PNG header (`Test.ImageFixtures.png_uri/2`) in both
orientations and assert the resulting style, and `thumbnail_test.exs` covers
each format parser plus the fallbacks (nil, a non-data URL, non-base64,
truncated, an unknown format, a JPEG with no SOF).

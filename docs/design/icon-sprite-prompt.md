# Xipper: prompt per generare icone e grafica con ChatGPT

Questo file serve a generare con ChatGPT (generazione immagini) gli sprite da cui Claude ricava le risorse dell'app. Le icone vengono ridisegnate in SVG, vettoriali e pulite; servono anche le varianti piccole, i badge dei documenti e i template per la barra dei menu. Gli sprite sono quindi **riferimenti di stile e di forma**, non risorse finali.

## Come usarlo

1. In ChatGPT incolla **una sezione alla volta**: prima la "Guida di stile comune", poi uno dei prompt (Sprite A, Sprite B, Immagine C, Immagine D).
2. Chiedi il formato indicato nel prompt: `1024×1024` per gli sprite, `1536×1024` per le immagini orizzontali.
3. Rigenera finché la griglia non è rispettata: ogni cella al suo posto, niente testo dentro le icone, sfondo uniforme.
4. Salva i PNG in `docs/design/sprites/` con questi nomi:
   - `sprite-a-app.png`
   - `sprite-b-formats.png`
   - `dmg-background.png`
   - `onboarding-hero.png`
5. Chiedi a Claude di "lavorare gli sprite". Claude li taglia, ridisegna ogni elemento in SVG e li integra nel progetto:
   - icona dell'app: `scripts/make-app-icon.py`, `AppIcon.icon`;
   - icone dei documenti: `UTTypeIcons` in `Info.plist`;
   - simboli template in `Assets.xcassets`;
   - sfondo del DMG: `scripts/release.sh`.

Se il risultato non convince, rigenera solo la cella da rifare con il prompt "Correzione di una cella" in fondo.

---

## Guida di stile comune (incollala sempre per prima)

```text
You are designing the visual identity of "Xipper", a native macOS 26 file archiver for Apple Silicon
(it creates and extracts ZIP, 7z, tar, Apple Archive and its own XIZ format). The look must sit
naturally next to Apple's own apps on macOS 26 ("Liquid Glass" era).

Brand
- Core symbol: a bold white "X" whose two strokes have short zipper teeth on both sides of the
  crossing, like a zipper closing into an X. Rounded stroke caps, no outlines, no shadows inside.
- Primary gradient: top-left #4AA3FF to bottom-right #0A57D4 (bright sky blue to deep blue).
- Neutrals: graphite #1C1C1E, mid grey #8E8E93, light grey #E5E5EA, white #FFFFFF.
- Accent colors only for format badges (listed per cell), always muted and harmonious, never neon.

Drawing rules
- Flat vector style with at most one soft gradient per shape, like SF Symbols and Apple app icons.
- Consistent geometry: same stroke weight within a sheet, rounded joins, generous padding (each
  item uses at most the central 76% of its cell).
- NO text, letters or numbers anywhere unless a cell explicitly asks for them.
- NO drop shadows outside shapes, NO 3D bevels, NO photorealism, NO mockup scenes.
- Perfectly even background for the whole sheet as specified, so items can be cut out cleanly.
- Grids are invisible: do not draw grid lines, frames or labels; just place each item centered in
  its cell.
```

---

## Sprite A: icona dell'app e simboli dell'interfaccia

Formato richiesto: **1024×1024**, griglia 4×4 di celle da 256 px. Sfondo: grigio chiaro uniforme `#F2F2F7`.

```text
Create a 1024x1024 sprite sheet on a flat uniform #F2F2F7 background, arranged as an invisible
4x4 grid of 256x256 cells. Follow the Xipper style guide. Fill the cells exactly as follows
(row 1 is the top row, column 1 is the left column):

Row 1 - app icon family (macOS 26 rounded-square "squircle" app icon shape, each centered in its cell):
  1. Main app icon: squircle filled with the blue gradient #4AA3FF -> #0A57D4, white zipper-X glyph
     with teeth, centered, glyph occupying about 64% of the squircle.
  2. Dark-mode variant: graphite #1C1C1E squircle, the zipper-X glyph in the blue gradient.
  3. Tinted/monochrome variant: light grey squircle, glyph in solid mid grey #8E8E93.
  4. Small-size variant for 16-32 px: same as cell 1 but the glyph is ONLY a thick white X,
     no teeth, strokes 30% thicker so it stays readable when tiny.

Row 2 - monochrome template glyphs (solid black #000000 on the background, no squircle, like SF Symbols, medium weight):
  1. Menu bar glyph: the zipper-X, simplified (X plus two teeth per arm), must read at 16x16.
  2. "Compress" action: two arrows pointing diagonally inward toward a small zipper-X center.
  3. "Extract" action: an open box/tray with an arrow coming out upward-right.
  4. "Verify" action: a shield with a check mark whose stroke ends in one zipper tooth.

Row 3 - document badges (small symbols that will be overlaid on file icons; solid colors, no background plate):
  1. Encrypted: a padlock in deep blue #0A57D4 with a tiny zipper-X engraved on the body.
  2. Damaged: an orange #FF9F0A triangle with an exclamation mark made of a broken zipper.
  3. Beta: a small rounded tag shape in purple #8E5CF7 with a sparkle, no letters.
  4. Genomics: a DNA double helix in teal #30B0C7 whose rungs look like zipper teeth.

Row 4 - empty-state and status illustrations (simple, friendly, flat, blue gradient + greys):
  1. Drop zone: a dashed rounded rectangle with the zipper-X glyph and two inward arrows.
  2. Archive opened: an open geometric box (flat, not cardboard) with a few file sheets
     rising out of it.
  3. All good: a large check mark inside a circle, check stroke with zipper teeth.
  4. Job in progress: a circular progress ring 70% filled in the blue gradient around a small zipper-X.
```

---

## Sprite B: badge dei formati d'archivio

Su macOS 26 il sistema disegna da solo il foglio del documento e scrive l'estensione. A noi serve solo il **badge centrale** di ogni formato.

Formato richiesto: **1024×1024**, griglia 4×4 di celle da 256 px. Sfondo: bianco uniforme `#FFFFFF`.

```text
Create a 1024x1024 sprite sheet on a flat uniform white #FFFFFF background, arranged as an invisible
4x4 grid of 256x256 cells. Follow the Xipper style guide. Each cell contains ONE format badge: a
simple centered pictogram (no document page, no text, no letters) built from the zipper-X visual
language plus a distinctive shape, using the listed accent color with the blue gradient as a
secondary touch. All badges share the same visual weight and size (about 60% of the cell).

Row 1:
  1. ZIP - a classic zipper pull tab, closed zipper line; accent blue #0A84FF.
  2. 7z - a heavy, dense cube made of stacked layers (high compression); accent indigo #5E5CE6.
  3. TAR - a roll of tape / spool with a bundle of sheets; accent brown #A2845E.
  4. GZ (gzip) - a sheet squeezed by a clamp; accent green #34C759.

Row 2:
  1. BZ2 (bzip2) - two interlocking blocks; accent olive #8FA33B.
  2. XZ - a narrow diamond being compressed by two chevrons; accent teal #30B0C7.
  3. ZST (Zstandard) - a lightning bolt crossing a compressed bar (speed); accent orange #FF9F0A.
  4. AAR (Apple Archive) - a rounded box with a ribbon, elegant; accent graphite #636366.

Row 3:
  1. CPIO - a stack of punched cards; accent slate #6E7B8B.
  2. LZ4 - a fast arrow with motion lines; accent yellow #FFD60A (dark outline for contrast).
  3. BR (Brotli) - a stylized brotli bread loaf made of compressed lines; accent wheat #D9A55B.
  4. XIZ (Xipper's own format) - the zipper-X inside a hexagon, premium feel, blue gradient + purple #8E5CF7 glow.

Row 4:
  1. BGZF (genomics) - a DNA helix inside a compressed block; accent teal #30B0C7.
  2. Split volume (.001) - three overlapping slices of the same box, offset diagonally; accent blue #0A84FF.
  3. Encrypted archive (AEA / ZIP AES) - a closed box with a padlock; accent deep blue #0A57D4.
  4. Generic archive - a simple neutral box with the zipper-X on the front; accent mid grey #8E8E93.
```

---

## Immagine C: sfondo della finestra del DMG

Formato richiesto: **1536×1024** (orizzontale). Claude lo riduce a 660×400 pt @2x.

```text
Create a 1536x1024 background image for a macOS disk-image installer window, following the Xipper
style guide. Very calm and minimal: a soft light background fading from #F5F9FF (top) to #E6F0FF
(bottom), with a subtle, large, low-contrast zipper-X watermark in the lower right (opacity ~6%).
Leave two empty circular areas, centered vertically at 45% height: one at 28% of the width (where
the app icon will sit) and one at 72% of the width (where the Applications folder will sit).
Between them draw a single elegant curved arrow in the blue gradient pointing from left to right.
No text, no icons inside the empty areas, no window chrome.
```

---

## Immagine D: illustrazione di benvenuto (onboarding)

Formato richiesto: **1536×1024**. Va nella prima schermata dell'app, sopra il testo "Benvenuto in Xipper".

```text
Create a 1536x1024 hero illustration for the welcome screen of the Xipper macOS app, following the
style guide. Flat vector, airy composition on a transparent-looking very light background #F8FAFF:
in the center the Xipper app icon (blue gradient squircle with the white zipper-X), slightly
floating; around it, in a loose orbit, small flat document sheets and folders being zipped into
it, plus three tiny format badges (a zipper tab, a layered cube, a DNA helix). Soft glassy circles
in the background suggest macOS Liquid Glass. Lots of empty space at the bottom 30% for text.
No text, no letters, no UI chrome, no people.
```

---

## Correzione di una cella

```text
Regenerate the same sprite sheet keeping every cell identical, except row <R> column <C>: <describe
what to change>. Keep the exact same grid positions, background color, style and sizes.
```

## Note per Claude (lavorazione)

- Tagliare gli sprite con la griglia 256 px, rimuovere lo sfondo uniforme e ridisegnare in SVG con geometria pulita (traccia uniforme, angoli arrotondati) usando i PNG solo come riferimento.
- **Icona dell'app:** aggiornare `scripts/make-app-icon.py`. Il glifo senza denti è la variante sotto i 32 pt (UI_SPEC §11).
- **Badge dei formati:**
  - tipi esportati (`app.xipper.*`): `UTTypeIcons` con `UTTypeIconBadgeName`, `UTTypeIconText` e `UTTypeIconBackgroundName`;
  - tipi di sistema: `CFBundleTypeIconSystemGenerated` in `CFBundleDocumentTypes`.
- **Template della riga 2 dello Sprite A:** symbol image in `Assets.xcassets`, al posto degli SF Symbols solo dove il simbolo di sistema non esiste.
- **Sfondo del DMG:** in `scripts/release.sh`, con la posizione delle icone allineata ai due cerchi vuoti.

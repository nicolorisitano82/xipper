# Xipper: prompt per le icone dei file (sprite C)

Serve a generare con ChatGPT le **icone dei documenti** per ogni formato d'archivio. Oggi nel Finder c'è un rettangolo con il nome del formato, disegnato dall'estensione delle miniature.

Lo sprite è un riferimento di stile e di forma: Claude ridisegna ogni icona in SVG (pagina, piega, pittogramma), aggiunge l'**etichetta del formato in testo vero** (nitida e senza errori di ortografia) e le integra in due punti:
- le miniature del Finder (`XipperThumbnail`);
- le icone dei documenti (`.icns` per ogni tipo in `Info.plist`) per i formati di cui Xipper è l'app predefinita.

## Come usarlo

1. In ChatGPT incolla prima la **Guida di stile comune** di [icon-sprite-prompt.md](icon-sprite-prompt.md), poi il prompt qui sotto.
2. Chiedi un'immagine **1024×1024**.
3. Rigenera finché:
   - le 16 celle sono al loro posto;
   - le pagine hanno tutte la stessa forma;
   - **non c'è testo**.
4. Salva il PNG come `docs/design/sprites/sprite-c-file-icons.png` e chiedi a Claude di "lavorare lo sprite C".

---

## Prompt

```text
Create a 1024x1024 sprite sheet on a flat uniform #F2F2F7 background, arranged as an invisible 4x4
grid of 256x256 cells. Follow the Xipper style guide. Each cell holds ONE macOS 26 document icon for
an archive format, centered, all sixteen identical in shape and size.

The document shape (identical in every cell):
- a portrait sheet of paper, width:height = 0.78:1, about 78% of the cell height, rounded corners,
  with a folded top-right corner (dog-ear) showing a slightly darker underside;
- the paper is very light (#FFFFFF to #F4F6FA vertical gradient) with a hairline border (#D9DDE5)
  and a soft, short contact shadow at the bottom only;
- the lower 28% of the page is EMPTY (no drawing, no text): a format label will be added there later;
- in the upper 62% of the page sits the format's pictogram, flat and colorful, like the large
  symbol on Apple's own document icons (Pages, Keynote, Xcode files).

NO TEXT, NO LETTERS, NO NUMBERS anywhere. Keep pictograms simple, bold and readable at 32x32 px,
using the zipper-X visual language of the Xipper app icon where it fits (white zipper teeth,
rounded strokes), with the listed accent color.

Row 1:
  1. ZIP: a zipper running vertically down the page center, closed, with a small pull tab; blue #0A84FF.
  2. 7z: a heavy cube made of stacked compressed layers; indigo #5E5CE6.
  3. TAR: a bundle of three sheets tied with a band; brown #A2845E.
  4. GZ (gzip): a single sheet squeezed thin by a clamp; green #34C759.

Row 2:
  1. BZ2 (bzip2): two interlocking blocks; olive #8FA33B.
  2. XZ: a tall narrow diamond squeezed by two chevrons; teal #30B0C7.
  3. ZST (Zstandard): a lightning bolt across a compressed bar; orange #FF9F0A.
  4. AAR (Apple Archive): an elegant rounded box with a ribbon; graphite #636366.

Row 3:
  1. CPIO: a stack of punched cards; slate #6E7B8B.
  2. LZ4: a fast arrow with motion lines; golden yellow #FFC300 with a darker outline.
  3. BR (Brotli): a loaf made of compressed horizontal lines; wheat #D9A55B.
  4. XIZ (Xipper's own format): the white zipper-X on a rounded blue gradient tile
     (#4AA3FF to #0A57D4) with a soft purple glow #8E5CF7. This one should feel premium.

Row 4:
  1. BGZF / genomics: a DNA double helix whose rungs look like zipper teeth; teal #30B0C7.
  2. Split volume (.001, .z01): three overlapping slices of the same box, offset diagonally; blue #0A84FF.
  3. Encrypted archive: a closed box with a padlock in front; deep blue #0A57D4.
  4. Generic archive: a neutral box with the zipper-X on its front; mid grey #8E8E93.
```

## Correzione di una cella

```text
Regenerate the same sprite sheet keeping every cell identical, except row <R> column <C>: <what to
change>. Same document shape, same empty label area, no text.
```

## Note per Claude (lavorazione)

- **Pagina:** ridisegnarla una volta sola in SVG e usarla per tutte le icone, così sono identiche. I pittogrammi vanno ridisegnati per cella, prendendo lo sprite come riferimento.
- **Etichetta:** testo vero nella fascia in basso, maiuscolo e in grassetto arrotondato, nel colore d'accento. Valori: ZIP, 7Z, TAR, TGZ/GZ, TBZ/BZ2, TXZ/XZ, TZST/ZST, AAR, CPIO, LZ4, BR, XIZ, BGZF, 001, cifrato (lucchetto, senza testo) e ARCHIVIO.
- **Miniature del Finder:** `XipperThumbnail` disegna l'icona del formato riconosciuto, al posto del rettangolo attuale; per gli ZIP aggiunge il numero di file come piccolo badge.
- **Icone dei documenti:**
  - un `CFBundleDocumentTypes` per famiglia di formati, ognuno con il suo `CFBundleTypeIconFile` (`.icns` generato dall'SVG a 16–1024 px);
  - togliere `CFBundleTypeIconSystemGenerated`;
  - i formati di cui Xipper non è l'app predefinita mantengono l'icona di sistema.

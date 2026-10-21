# Xipper — specifica UI per l'implementazione SwiftUI

Fonte visiva: canvas [Xipper — Flussi Liquid Glass](https://claude.ai/artifact/CspdHhiqFhGPGUY36aTxjs) (40 tavole). I numeri tra parentesi, per esempio **(2.4)**, sono quelli delle tavole. Principi: `STUDIO.md` §6-bis. Target: macOS 26, solo arm64.

Le sezioni seguono l'ordine d'implementazione. Le parti marcate **[non sul canvas]** sono specificate solo qui: Impostazioni › Integrazioni › MCP e Impostazioni › Genomica.

---

## 0. Convenzioni comuni

### 0.1 Regole del vetro
| Regola | In pratica |
|---|---|
| Il vetro serve alla navigazione e ai controlli, mai al contenuto | In vetro: toolbar, sidebar, barra d'azione flottante, HUD, pannello di avanzamento, banner di esito. Opachi: `Table`, testi, form delle Impostazioni, anteprime |
| Mai vetro su vetro | Dentro un pannello di vetro si usano superfici opache (`.background(.background.secondary)`) o pulsanti `.glass` gestiti dal sistema. Niente card in vetro dentro la sidebar. I banner tinti stanno sul contenuto, mai dentro uno sheet |
| Una sola `.glassProminent` per vista | È l'azione primaria. Negli stati di attesa (avanzamento) non ce n'è nessuna. Nei dialoghi di sicurezza la prominente è l'azione **sicura** |
| Tinta solo semantica | `.tint(.red)` per errori (5.2, 2.8) e `.tint(.orange)` per avvisi di sicurezza (6.3). Mai decorativa |
| Componenti di sistema prima di tutto | `NavigationSplitView`, `.toolbar`, `.inspector`, `.sheet`, `.alert`/`.confirmationDialog`, `Form(.grouped)`, `Settings`. Vetro personalizzato (`glassEffect`) solo per: zona di rilascio e barra d'azione (2.x), pannello di avanzamento ed esito (2.4, 2.5, 2.6, 2.8), HUD (7.1), banner di esito (5.2, 6.3) |

### 0.2 Misure
| Elemento | Valore indicativo |
|---|---|
| Raggio della finestra | di sistema (circa 26 pt); il resto è concentrico con `ConcentricRectangle` / `.containerShape` |
| Sidebar flottante | margine 8 pt → raggio 18; righe alte 28, raggio 10 |
| Toolbar | alta circa 52 pt; pulsanti 32 pt (capsula); gruppi separati da `ToolbarSpacer` |
| Barra d'azione Home | capsula alta 44 pt, a 28 pt dal bordo inferiore, centrata |
| Pannello di avanzamento | largo circa 540 pt, raggio 30, padding 28–30 |
| HUD | largo 380 pt, raggio 24, margine 16 dal bordo della finestra; capsula compatta alta 40 |
| Inspector | largo 262 pt (`.inspectorColumnWidth(min: 240, ideal: 262)`) |
| Sheet | larghezza 420–500 pt, padding 22–24 |
| Righe di `Table` | altezza di sistema (circa 27 pt); numeri in `.monospacedDigit()` |

### 0.3 Accessibilità e modalità scura
- **Riduci trasparenza** (`@Environment(\.accessibilityReduceTransparency)`): il vetro personalizzato passa a `Glass.identity` su una superficie piena (`.background(.regularMaterial)` → colore solido di finestra) con un bordo a 1 pt `separatorColor`. I componenti di sistema si adattano da soli.
- **Aumenta contrasto** (`\.colorSchemeContrast == .increased`) (10.1): il vetro personalizzato diventa pieno con bordo a 1,5 pt `.primary`. Separatori e testi secondari più scuri: si usano i colori semantici (`.secondary`, `separatorColor`), mai grigi fissi.
- **Riduci movimento** (`\.accessibilityReduceMotion`) (10.2): ogni `glassEffectID`/morph diventa una dissolvenza (`.transition(.opacity)`, circa 150 ms). Niente scuotimento del campo password (4.3): restano solo colore e messaggio.
- **Modalità scura:** solo colori semantici (`.primary`, `.secondary`, `Color.accentColor`, `.red`, `.orange`, `.green`) e materiali di sistema. Nel canvas sono scure per default le tavole 2.4, 2.8, 3.2, 4.3, 5.2, 6.3, 7.1, 8.2 e 9.2. Le anteprime dei documenti (3.4) restano su fondo bianco anche in scuro.
- Pulsanti solo icona: sempre con `.help()` e `accessibilityLabel` uguale all'etichetta italiana indicata.

### 0.4 Formati disponibili
XipperKit oggi: zip (AES-256), tar.gz/bz2/xz/zst, gz, BGZF. **7z non c'è ancora.** Nell'interfaccia le voci 7z (menu Formato, preset «Lungo termine», «Cifra anche i nomi dei file», miniature 7z) restano nascoste finché il core non lo supporta. Il preset «Lungo termine» intanto usa tar.xz.

### 0.5 SF Symbols
| Uso | Simbolo |
|---|---|
| Archivio | `archivebox` |
| Comprimi | `arrow.down.right.and.arrow.up.left` |
| Estrai | `arrow.down.to.line` |
| Aggiungi / Elimina | `plus` / `trash` |
| Verifica | `checkmark.shield` |
| Esito positivo / errore | `checkmark.circle.fill` (verde) / `xmark.circle.fill` (rosso) |
| Avviso | `exclamationmark.triangle.fill` (arancione) |
| Cifrato | `lock.fill` (tabelle), `lock` (pulsanti) |
| Touch ID / Portachiavi | `touchid` / `key` |
| Bloc Maiusc | `capslock.fill` |
| Cartella / file / immagine / video | `folder.fill` / `doc` / `photo` / `film` |
| Symlink | `link` |
| Info | `info.circle` |
| Mostra nel Finder | `arrow.up.forward` |
| Pausa | `pause.fill` |
| Core | `cpu` |
| Velocità | `bolt` |
| Volume montato | `externaldrive` · espelli `eject` |
| Quick Look / Apri con Anteprima | `eye` |
| Comandi Rapidi | `wand.and.stars` |
| Preset | `square.stack.3d.up` |
| Recenti / In coda | `clock` |
| Preferiti | `star` |
| Terminale | `terminal` |
| Impostazioni › Generali / Formati / Sicurezza / Integrazioni / Genomica / Prestazioni | `gearshape` / `archivebox` / `lock` / `square.stack.3d.up` / `testtube.2` / `cpu` |
| MCP / agenti | `point.3.connected.trianglepath.dotted` |

Prima di chiudere l'elenco conviene verificare i nomi in SF Symbols 7.

---

## 1. Home / Drop — (2.1)

**Struttura:** `WindowGroup` senza documento aperto, circa 760×580 pt. Toolbar: titolo «Xipper» e, a destra, `Button("Apri archivio…", systemImage: "archivebox").buttonStyle(.glass)`.

**Contenuto (opaco):**
- Zona di rilascio con inset 24 pt; in basso lascia 104 pt per la barra.
- Bordo tratteggiato 1,5 pt (`RoundedRectangle` concentrico, `StrokeStyle(dash:)`).
- Icona `arrow.down.right.and.arrow.up.left` a 56 pt.
- Titolo: **«Trascina qui file o cartelle»**.
- Sottotitolo: «per creare un archivio. Rilascia un archivio per aprirlo.»
- Riga «Recenti» con 3 capsule (`.buttonStyle(.bordered)`, piccole). Un archivio cifrato mostra `lock`.
- `.onDrop` / `dropDestination(for: URL.self)`. Durante il trascinamento (`isTargeted`) il bordo diventa pieno, 2 pt, accent, con fondo accent al 7%.

**Barra d'azione (vetro):**
- `GlassEffectContainer` con una capsula `glassEffect(.regular, in: .capsule)` che contiene:
  - `Menu` Formato («ZIP»);
  - `Menu` Livello («Normale»);
  - `Button("Password", systemImage: "lock")`.
- Accanto, fuori dalla capsula: `Button("Comprimi").buttonStyle(.glassProminent)`, `.disabled(true)` finché non ci sono file.
- Divisori verticali di 1 pt tra gli elementi della capsula.

**Transizioni:**
- Rilascio di file → 2.2 (stessa finestra, la zona diventa la lista).
- Rilascio di un archivio → 3.1.
- Clic su un Recente → 3.1, oppure → 4.x se cifrato.

**Riduci trasparenza:** la capsula diventa piena con bordo. **Scuro:** colori di sistema.

---

## 2. Creazione e opzioni — (2.2, 2.3, 2.6, 2.7, 2.8)

### 2.2 File rilasciati
- **Toolbar:**
  - titolo «Nuovo archivio», sottotitolo «12 elementi · 4,62 GB»;
  - a destra un gruppo `.glass` con `plus` («Aggiungi file») e `trash` («Rimuovi dalla lista»).
- **Sopra la lista:**
  - `TextField` **«Nome»** con il suffisso dell'estensione in `.secondary` (per esempio «.zip»);
  - pop-up **«Salva in»** con «Scrivania» e il simbolo `folder.fill`.
- **Lista (opaca):** `Table` con colonne Nome · Tipo · Dimensione, raggio 16, bordo `separator`.
  - Sotto una cartella: «Cartella · 1.206 elementi».
  - Ultima riga di riepilogo: «+ altri 5 elementi · .DS_Store e __MACOSX esclusi».
- **Menu Formato (pop-up di sistema):**
  - sezione «Formato»: «ZIP — si apre ovunque» (✓), «7z — rapporto massimo» (nascosto, §0.4), «tar.zst — il più veloce», «tar.xz — compatto», «tar.gz — Linux e server», «tar.bz2»;
  - sezione «Preset»: «Email · ZIP, parti da 25 MB», «Archivio lungo termine · 7z Ultra», «Backup veloce · tar.zst».
  - Il secondo testo di ogni voce è un `Text` secondario allineato a destra.
- **Menu Livello:** Veloce / Normale / Massimo (i nomi dei livelli sono da confermare con il core).
- **Comprimi** (`.glassProminent`, capsula da 44 pt) → 2.4.

### 2.3 Sheet «Proteggi con password»
- `.sheet`, larghezza 470. Intestazione: `lock` 40 pt in accent, titolo **«Proteggi con password»**, sottotitolo «Senza password l'archivio non si potrà aprire. Xipper non può recuperarla.»
- **Campi:**
  - `SecureField` «Password», con il focus;
  - indicatore di robustezza: `ProgressView(value:)` con `.tint` verde/arancione/rosso e testo «Robusta» / «Media» / «Debole»;
  - `SecureField` «Conferma».
- **Altre righe:**
  - «Cifratura»: pop-up «AES-256 (consigliata)» / «ZipCrypto (compatibilità)»;
  - `Toggle` «Cifra anche i nomi dei file», disattivato per ZIP, con la nota «Disponibile con il formato 7z. In ZIP i nomi restano visibili.» (nasconderlo finché manca 7z);
  - `Toggle` «Salva nel Portachiavi, sbloccabile con Touch ID», attivo.
- **Pulsanti:** «Annulla» (`.glass`) · **«Imposta password»** (`.glassProminent`, `.keyboardShortcut(.defaultAction)`).
- **Dopo la conferma:** nella barra d'azione il simbolo diventa `lock.fill` e il testo resta «Password».

### 2.7 Avviso ZipCrypto (scelta di «ZipCrypto (compatibilità)» nello sheet)
- **Nello stesso sheet**, sotto la riga Cifratura, compare un riquadro **opaco** arancione al 12% (non vetro), con `exclamationmark.triangle.fill` arancione.
  - Titolo: **«ZipCrypto è una cifratura debole»**.
  - Testo: «Chi possiede anche uno solo dei file in chiaro (per esempio un PDF già inviato per email) può ricavare la chiave e aprire tutto l'archivio in pochi minuti.»
  - Secondo paragrafo: «Usalo solo se chi riceve ha un programma che non supporta AES. 7-Zip, WinRAR, Keka e Xipper aprono gli archivi AES-256.»
- **Pulsanti:** «Annulla» (a sinistra) · «Usa ZipCrypto» (`.glass`) · **«Usa AES-256»** (`.glassProminent`).

### 2.6 Completato in più parti (preset Email)
- Stesso pannello di 2.5. Titolo **«Archivio creato in 3 parti»**, sottotitolo «62,4 MB divisi in parti da 25 MB, sulla Scrivania».
- Tabella opaca delle parti (`Preventivo-Rossi.z01` 25,0 MB, `.z02` 25,0 MB, `.zip` 12,4 MB).
- Nota: «Per aprirlo servono tutte e 3 le parti nella stessa cartella. Chi lo riceve può usare Xipper, 7-Zip o WinRAR: Utility Archivio non apre gli ZIP divisi.» (affermazione da verificare prima del rilascio).
- Pulsanti: «Condividi…» (`.glass`, `ShareLink`) · **«Mostra nel Finder»** (`.glassProminent`).
- Richiede la divisione in parti nel core: da verificare se XipperKit la supporta.

### 2.8 Errore: disco pieno
- Il pannello di 2.4 resta al suo posto e si tinge: `glassEffect(.regular.tint(.red))`.
- Intestazione: `xmark.circle.fill` rosso, **«Spazio su disco esaurito»**, sottotitolo «La compressione si è fermata al 71%.» La barra di avanzamento diventa rossa.
- `Grid` con chiave e valore:

| Chiave | Valore |
|---|---|
| Spazio libero sulla Scrivania | 120 MB |
| Spazio ancora necessario | circa 1,1 GB |
| File parziale | eliminato |
| Originali | intatti, nessun file è stato modificato |

- Pulsanti: «Annulla» (a sinistra) · «Riprova» · **«Salva altrove…»** (`.glassProminent`, apre `NSSavePanel`).
- Lo stesso schema vale per gli altri errori di scrittura (permessi, volume rimosso): cambiano titolo e righe.

---

## 3. Avanzamento e HUD — (2.4, 2.5, 7.1, 7.2)

### 2.4 Avanzamento in finestra
- **Morph:** la zona di rilascio e la barra d'azione si fondono nel pannello. Si usa `GlassEffectContainer` con `glassEffectID("job", in: ns)` su entrambe le forme e `withAnimation(.smooth)`. Con Riduci movimento: dissolvenza.
- **Pannello di vetro (`glassEffect(.regular, in: .rect(cornerRadius: 30))`):**
  - Riga 1: `arrow.down.right.and.arrow.up.left` in accent, **«Compressione in corso»**, sottotitolo «12 elementi · 2.418 file», badge capsula `bolt` **«7,5× Utility Archivio»**. Il badge appare solo se il confronto è misurato o noto per quel formato.
  - Velocità grande: «372» a 44 pt bold, `.monospacedDigit()`, seguito da «MB/s» a 17 pt. A destra la percentuale «62%». Il valore va smussato (media mobile di 1 s) e aggiornato al massimo 4 volte al secondo.
  - `ProgressView` lineare alta 8 pt, poi la riga «2,86 GB di 4,62 GB» · «circa 5 secondi».
  - «File corrente» con il percorso in monospazio, troncato a metà.
  - Barre dei core: 10 P-core in accent e 4 E-core grigi, con la didascalia «10 P-core al lavoro · E-core liberi per il sistema». È facoltativo: solo se il core espone l'occupazione.
  - Pulsanti: «Nascondi» (`.glass`) → il lavoro passa all'HUD (7.1); «Annulla» (`.glass`) → cancellazione, poi torna a 2.1. **Nessuna** `.glassProminent`.

### 2.5 Completato
- Il pannello resta dov'è e il contenuto passa con dissolvenza.
- `checkmark.circle.fill` verde 56 pt, **«Archivio creato»**, «Progetto-Atlante.zip, sulla Scrivania».
- Tre riquadri opachi (`.background(.background.secondary)`):

| Riquadro | Valore | Riga sotto |
|---|---|---|
| Dimensione | 3,05 GB | da 4,62 GB · −34% |
| Tempo | 12,6 s | Utility Archivio: ~95 s |
| Velocità media | 367 MB/s | 10 P-core |

- Nota: `lock` «Cifrato con AES-256 · password salvata nel Portachiavi».
- Pulsanti: «Verifica» (`checkmark.shield`) · «Mostra contenuto» · **«Mostra nel Finder»** (`.glassProminent`). Sotto, il link «Crea un altro archivio».

### 7.1 HUD dei lavori
- **Dove:** overlay in basso a destra della finestra attiva (`.overlay(alignment: .bottomTrailing)`, margine 16). Se nessuna finestra è aperta, un `NSPanel` flottante non attivante.
- **Più lavori:** un `GlassEffectContainer` unico; ogni lavoro è una forma con `glassEffectUnion(id: "jobs", namespace:)` e le forme si fondono. Separatori interni di 1 pt.
- **Lavoro espanso (il primo):** nome, percentuale, barra, «**372 MB/s** · 7,5× Utility Archivio» · «circa 5 s», file corrente in monospazio. Pulsanti piccoli «Pausa» (`pause.fill`) e «Annulla», con fondo opaco tenue (non vetro).
- **Lavori compressi:** una riga ciascuno con icona, nome, mini-barra da 80 pt e velocità («1,4 GB/s»). In coda: `clock` e «In coda · E-core».
- **Capsula compatta:** anello di avanzamento complessivo, «3 lavori», «46% · 5 s». Un clic la espande (`glassEffectID`), un clic fuori la richiude.
- **Dock:** `NSApp.dockTile` con vista personalizzata (barra di avanzamento in basso sull'icona) e `badgeLabel` uguale al numero di lavori.

### 7.2 Notifiche e menu bar extra
Le notifiche usano `UNUserNotificationCenter`, con categorie e azioni:

| Notifica | Testo | Azioni |
|---|---|---|
| Archivio creato | «Progetto-Atlante.zip · 3,05 GB in 12,6 s (367 MB/s)» | «Mostra nel Finder», «Verifica» |
| Estrazione completata | «Foto-2025.7z → Download/Foto-2025 · 1.284 file» | — |
| Verifica non riuscita | «backup-clienti.zip: 3 voci danneggiate su 1.912» | «Mostra rapporto»; resta nel Centro Notifiche |

Si inviano solo se l'app non è in primo piano.

**Menu bar extra** (facoltativo, `MenuBarExtra` con `.menuBarExtraStyle(.window)`):
- intestazione con icona dell'app, «Xipper» e «2 lavori attivi»;
- una riga per lavoro, con barra;
- «Cartelle sorvegliate»: nome, preset e pianificazione;
- «Apri Xipper», «Impostazioni…» (⌘,).
- Si attiva con Impostazioni › Integrazioni › «Icona nella barra dei menu».

---

## 4. Browser dell'archivio con inspector — (3.1, 3.2, 3.3, 3.4, 9.4)

### 3.1 Browser
- **Struttura:** `NavigationSplitView`. La sidebar flottante di sistema è in vetro.
  - Sezioni della sidebar: **Recenti** (archivi; `lock` se cifrati), **Preferiti** (`star`), **Preset** (`square.stack.3d.up`, con un sottotitolo a destra come «ZIP · 25 MB»), **Cartelle sorvegliate** («attiva»).
- **Toolbar** (gruppi in vetro separati da `ToolbarSpacer`):
  1. gruppo navigazione: `chevron.left` e `chevron.right`;
  2. titolo «Progetto-Atlante.zip» con sottotitolo «ZIP · AES-256 · 2.418 elementi» (`.navigationSubtitle`);
  3. **«Estrai»** `arrow.down.to.line` (`.glassProminent`);
  4. gruppo con `plus` («Aggiungi») e `trash` («Elimina»), attivo solo per formati modificabili;
  5. `checkmark.shield` («Verifica»);
  6. `externaldrive` («Monta come volume»);
  7. `.searchable` («Cerca»);
  8. `info.circle` (mostra o nasconde l'inspector).
- **Barra del percorso:** sotto la toolbar, alta 28: «`archivebox` Progetto-Atlante.zip › **Documenti**».
- **Contenuto:** `Table` opaca con `scrollEdgeEffectStyle(.hard, for: .top)`.
  - Colonne: Nome (icona e nome) · Dimensione · Compresso · Rapporto · Modificato · `lock.fill`.
  - Numeri allineati a destra; date nel formato «14 ott 2026»; symlink mostrati come «ultimo-report → Report_Q3.pdf».
  - Barra di stato in basso: «1 di 1.206 selezionati · 1,21 GB in Documenti».
- **Interazioni:**
  - doppio clic su una cartella → entra;
  - doppio clic su un file → 3.4;
  - trascinamento delle righe nel Finder → estrazione diretta (`NSItemProvider` con promessa di file);
  - barra spaziatrice → 3.4.
- **Inspector** (`.inspector`, opaco):
  - anteprima 120 pt (cliccabile → 3.4), nome, «Documento PDF · 8,4 MB»;
  - sezione **«Voce»**: Compresso, Metodo (per esempio «Deflate · livello 6»), Cifratura («AES-256 (AE-2)»), CRC-32 in monospazio, Permessi in monospazio, Modificato;
  - sezione **«Archivio»**: Formato («ZIP64 · 2.418 voci»), Dimensione, SHA-256 abbreviato, Quarantena («No (creato qui)» / «Sì, scaricato da …»), Formato BGZF quando rilevato;
  - pulsante a tutta larghezza «Verifica archivio» (`.glass`, piccolo).

### 3.2 Sheet «Estrai N elementi»
- Titolo **«Estrai 3 elementi»**, sottotitolo con i nomi e la dimensione totale.
- **Campi:**
  - «Destinazione»: pop-up con `folder.fill`, per esempio «Download › Progetto-Atlante»;
  - «Struttura»: radio «Mantieni le cartelle (Documenti/Contratti/…)» / «Solo i file, tutti nella destinazione»;
  - «Se un file esiste già»: pop-up «Chiedi ogni volta» / «Sostituisci» / «Mantieni entrambi» / «Salta», collegato alle politiche di sovrascrittura del core;
  - `Toggle` «Apri la cartella al termine».
- **Riquadro opaco** con `checkmark.shield` verde: «L'archivio viene da Internet: i file estratti restano in quarantena e Gatekeeper li controllerà alla prima apertura.» Compare solo se l'archivio ha `com.apple.quarantine`.
- **Pulsanti:** «Annulla» · **«Estrai 3 elementi»** (`.glassProminent`) → HUD.
- Con un solo archivio e niente selezione, «Estrai» usa direttamente l'estrazione **smart** (come Utility Archivio: niente cartella annidata se l'archivio ha un'unica cartella radice) senza sheet; ⌥-clic apre lo sheet.

### 3.3 File già esistente
- `.alert` di sistema con l'icona dell'app.
- Titolo: **«“Report_Q3.pdf” esiste già in Progetto-Atlante»**. Messaggio: «Scegli cosa fare con il file che stai estraendo.»
- Due riquadri opachi: «Nell'archivio» (8,4 MB · 14 ott 2026, 18:02 · badge «più recente») e «Sul disco» (8,1 MB · 2 ott 2026, 09:40).
- Checkbox «Applica agli altri 2 conflitti».
- Pulsanti: «Salta» (a sinistra) · «Sostituisci» · **«Mantieni entrambi»** (`.glassProminent`, default).
- Nota: «“Mantieni entrambi” salva la copia come “Report_Q3 2.pdf”. Sostituisci sposta il file sul disco nel Cestino.»
- L'estrazione resta in pausa finché non si risponde. Il sottotitolo della toolbar dice «Estrazione di 3 elementi · in pausa».

### 3.4 Quick Look di una voce
- `QLPreviewPanel` sopra il browser, con un `QLPreviewPanelDataSource` che fornisce URL temporanei.
- Il core (`readEntry`) estrae solo le voci selezionate in una cartella temporanea privata del container. La cartella viene eliminata alla chiusura del pannello e all'uscita dall'app. Le voci cifrate usano la password già sbloccata.
- Toolbar del pannello (di sistema): Chiudi, Schermo intero, frecce con «1 di 3», titolo con «12 pagine · 8,4 MB», «Apri con Anteprima» (`eye`) e **«Estrai…»** (prominente, → 3.2).
- Riga in basso: `lock` «Copia temporanea nello spazio privato dell'app · eliminata alla chiusura».

### 9.4 Archivio montato come volume (FSKit)
- «Monta come volume» (toolbar di 3.1 o menu del Finder) → l'archivio compare nel Finder sotto Posizioni, in sola lettura, con il pulsante Espelli.
- Notifica: **«Progetto-Atlante.zip montato»**, «Sfoglialo nel Finder come un disco: le app aprono i file senza estrarli.» Azioni «Apri in Xipper», «Espelli».
- Archivi cifrati: prima la password (sezione 5). MVP: ZIP e tar.

---

## 5. Password — (4.1, 4.2, 4.3)

**Logica all'apertura di un archivio cifrato:** se il Portachiavi ha una voce per quell'archivio si passa a 4.2, altrimenti a 4.1. Durante l'attesa il contenuto del browser mostra un placeholder: `lock` 56 pt, «Contenuto cifrato», «Anche i nomi dei file sono protetti» (solo se gli header sono cifrati). «Estrai» è disattivato.

### 4.1 Richiesta (`.sheet`, larghezza 420, centrato)
- `lock` 40 pt in accent, titolo **«“Foto-2025.7z” è protetto da password»**, messaggio «Inserisci la password per vedere ed estrarre il contenuto.»
- `SecureField` «Password», con il focus.
- `Toggle` «Ricorda nel Portachiavi (sblocco con Touch ID)», attivo per default.
- Pulsanti a larghezza uguale: «Annulla» · **«Apri»** (`.glassProminent`).

### 4.2 Portachiavi e Touch ID
- È il prompt di sistema di `LocalAuthentication`, generato dall'accesso alla voce del Portachiavi con `kSecAttrAccessControl` e `.biometryCurrentSet`. Non va ridisegnato.
- Testo passato al sistema (`localizedReason`): «usare la password salvata per “Foto-2025.7z”». Il sistema lo mostra come: «Xipper vuole usare la password salvata per “Foto-2025.7z”.»
- «Usa la password…» o Annulla → 4.1.

### 4.3 Password errata
- Lo stesso sheet di 4.1: `lock` rosso, campo con bordo rosso (`.overlay` con stroke `.red` e alone al 18%), `accessibilityValue` «non valida».
- Messaggio sotto il campo: `xmark.circle.fill` **«Password errata. Riprova.»**
- Se Bloc Maiusc è attivo: `capslock.fill` nel campo e la nota «Bloc Maiusc è attivo.»
- Il testo resta selezionato. Scuotimento orizzontale (3 oscillazioni, 0,3 s), disattivato con Riduci movimento.
- Nessun blocco dopo N tentativi.

---

## 6. Verifica — (5.1, 5.2)

Si avvia da: toolbar, inspector, notifica, menu del Finder, Comandi Rapidi, MCP. Durante la verifica l'avanzamento va nell'HUD in GB/s e non si scrive nulla su disco.

### 5.1 Esito positivo (`.sheet`, larghezza 640)
- `checkmark.circle.fill` verde 40 pt, **«Tutte le 2.418 voci sono integre»**, «CRC-32 e autenticazione AES verificati senza scrivere su disco · 1,4 s · 2,2 GB/s».
- Il vetro **non** si tinge.
- Lista opaca: `Picker(.segmented)` «Tutte» / «Solo errori» con il conteggio «2.418 integre · 0 errori» a destra.
- `Table` con colonne Voce · Dimensione · CRC-32 (monospazio) · Esito (`checkmark` verde «Integra»).
- Pulsanti: «Esporta SHA256SUMS…» (a sinistra, `.glass`) · **«Fine»** (`.glassProminent`).
- Per tar, al posto di CRC-32 compare il checksum del codec (CRC gzip, CRC64 xz, XXH64 zstd, CRC bzip2).

### 5.2 Voci danneggiate (nella finestra, non in uno sheet)
- Toolbar: `chevron.left` («Torna al contenuto»), titolo «Verifica di backup-clienti.zip», a destra «Verifica di nuovo» (`.glass`).
- **Banner di vetro tinto rosso**, flottante sotto la toolbar sul contenuto: `glassEffect(.regular.tint(.red), in: .rect(cornerRadius: 18))`, `role: status`.
  - `xmark.circle.fill`, **«3 voci danneggiate su 1.912»**, «Verifica completata in 0,9 s · nessun dato scritto su disco».
  - Pulsanti: «Esporta rapporto…» · **«Estrai voci integre…»** (`.glassProminent`, → 3.2 con le voci integre già selezionate).
- Filtro «Solo errori» attivo.
- `Table` con le righe in rosso; colonne Voce · Dimensione · Problema · Esito («Danneggiata»). Messaggi:
  - «CRC non corrispondente (atteso 1B07C4E2, letto 9D11A0F3)»
  - «Dati troncati: letti 61,0 MB su 212 MB»
  - «Autenticazione AES non valida: dati alterati»
  - BGZF: «Marker EOF mancante: file troncato»
- Nota sotto: «Le altre 1.909 voci sono integre e si possono estrarre. Riparazione non disponibile: l'archivio non contiene dati di recupero PAR2.»
- **Riduci trasparenza:** il banner diventa pieno, rosato in chiaro e bordeaux in scuro.

---

## 7. Avvisi di sicurezza in estrazione — (6.1, 6.2, 6.3)

### 6.1 Possibile zip-bomb (`.alert` di sistema, con l'icona dell'app e il badge di avviso)
- Titolo: **«Questo archivio si espande in modo anomalo»**.
- Messaggio: «“fattura_2026.zip” pesa 42 KB ma dichiara 4,5 PB di dati estratti. Potrebbe essere una zip-bomb, pensata per riempire il disco.»
- Dettagli (vista accessoria, `Grid`): Rapporto «1 : 107 milioni» · Voci sovrapposte «16 nella directory centrale» · Spazio libero «412 GB».
- Pulsanti in colonna: **«Non estrarre»** (prominente, default) · «Sposta nel Cestino» · «Estrai comunque…» (`role: .destructive`) → 6.2.
- Scatta quando si supera la soglia di rapporto o dimensione delle Impostazioni › Sicurezza.

### 6.2 Seconda conferma (`.sheet`, larghezza 470)
- `exclamationmark.triangle.fill` arancione, **«Estrarre comunque “fattura_2026.zip”?»**, «Dichiara 4,5 PB su un disco con 412 GB liberi.»
- Testo: «Xipper estrae finché i dati non superano il limite che scegli, poi si ferma ed elimina quanto scritto.»
- Campi:
  - pop-up «Ferma l'estrazione oltre» (1 GB / 10 GB / 50 GB);
  - `Toggle` «Estrai in una cartella nuova in Download», attivo;
  - `Toggle` «Fermati se resta meno del 10% di spazio libero», attivo e non modificabile, con la nota «Sempre attivo, non si può disattivare.»
- Pulsanti: «Estrai fino a 1 GB» (a sinistra, rosso) · **«Annulla»** (`.glassProminent`).

### 6.3 Elementi bloccati (nella finestra, dopo l'estrazione)
- Toolbar: titolo «Estrazione di pacchetto-driver.zip», sottotitolo «Completata con avvisi · 216 voci».
- **Banner di vetro tinto arancione** (`.tint(.orange)`): `exclamationmark.triangle.fill`, **«4 elementi bloccati per sicurezza»**, «Avrebbero scritto fuori dalla cartella di destinazione». Pulsanti: «Copia rapporto» · **«Mostra nel Finder»**.
- `Table` «Elementi bloccati» con colonne Voce nell'archivio (monospazio, icona arancione) · Motivo · Dove avrebbe scritto. Motivi:
  - «Percorso fuori dalla destinazione»
  - «Percorso assoluto»
  - «Symlink che punta fuori dalla destinazione»
  - «Scrittura attraverso un symlink esterno»
  - (core) «Hardlink verso l'esterno», «Bit setuid rimosso»
- Righe finali:
  - `checkmark.circle.fill` «212 elementi estratti in **Download/pacchetto-driver**.»
  - `checkmark.shield` «Gli eseguibili estratti restano in quarantena: Gatekeeper e XProtect li controlleranno alla prima apertura.»
  - `info.circle` «Questi elementi non si possono estrarre nemmeno su richiesta. Se ti servono, estrai l'archivio con un altro strumento a tuo rischio.»
- **Non** esiste «estrai comunque» per questi casi.

---

## 8. Impostazioni — (8.1–8.6)

**Struttura:** scena `Settings`, finestra di circa 700×700 pt.
- Schede nella toolbar di sistema (`TabView` con `.tabItem`, icona e testo): **Generali · Formati · Sicurezza · Integrazioni · Genomica · Prestazioni**.
- Contenuto `Form` + `.formStyle(.grouped)`, tutto opaco, senza vetro personalizzato.
- Intestazioni di sezione come nel canvas. Una riga con due righe di testo = `LabeledContent` con un `Text` secondario sotto.

### 8.1 Generali
| Sezione | Riga | Controllo | Default |
|---|---|---|---|
| Nuovi archivi | Formato predefinito | Picker | ZIP |
| | Livello di compressione | Picker | Normale |
| | Escludi i file di sistema di macOS — «.DS_Store, __MACOSX, ._* (resource fork)» | Toggle | on |
| | Salva l'archivio in | Picker | Stessa cartella degli originali |
| Estrazione | Estrai in | Picker | Cartella accanto all'archivio |
| | Crea una cartella solo se servono — «Un archivio con un'unica cartella non viene annidato» | Toggle (estrazione smart) | on |
| | Dopo l'estrazione | Picker | Mostra nel Finder |
| | Archivio originale | Picker | Lascialo dov'è |
| | Codifica dei nomi ZIP non UTF-8 — «Archivi creati da Windows con nomi accentati» | Picker | Automatica (CP437 / CP850) |

### 8.5 Formati
| Sezione | Riga | Controllo | Default |
|---|---|---|---|
| ZIP | Metodo | Picker | Deflate (si apre ovunque) |
| | Salva senza comprimere i file già compressi — «JPEG, HEIC, MP4, ZIP annidati: più veloce, stesso risultato» | Toggle (smart store) | on |
| | Dividi in parti — «Usato dal preset Email» | Picker | Mai |
| 7z | *(nascosta finché il core non supporta 7z)* Metodo LZMA2 · Dizionario 64 MB · Archivio solido | | |
| tar | Compressione predefinita | Picker | zstd, livello 3 |
| | Conserva permessi, attributi estesi e ACL — «Utile per backup da ripristinare su un Mac» | Toggle | on |
| | xz e zstd multi-thread — «Blocchi indipendenti: archivi leggibili da qualsiasi xz e zstd» | Toggle | on |

### 8.2 Sicurezza
| Sezione | Riga | Controllo | Default |
|---|---|---|---|
| Cifratura | Algoritmo per ZIP | Picker | AES-256 (AE-2) |
| | Consenti ZipCrypto per compatibilità — sottotitolo arancione «Debole: si rompe con un attacco a testo in chiaro noto» | Toggle | off |
| | Cifra i nomi dei file negli archivi 7z — «Senza password non si vede nemmeno l'elenco» | Toggle (nascosto senza 7z) | on |
| | Password nel Portachiavi — «Sbloccate con Touch ID; mai su disco né nei log» | Picker | Chiedi ogni volta |
| Estrazione | Propaga la quarantena ai file estratti — «Gatekeeper e XProtect controllano gli eseguibili scaricati» | Toggle | on |
| | Chiedi conferma oltre il rapporto — «Protezione dalle zip-bomb» | Picker | 1 : 1.000 |
| | Chiedi conferma oltre la dimensione — «Mai oltre lo spazio libero meno 10%» | Picker | 50 GB |
| | Percorsi esterni, assoluti e symlink fuori destinazione — «Bloccati sempre: non si può disattivare» | badge verde `checkmark.shield` «Sempre attivo» | — |

### 8.3 Integrazioni
| Sezione | Riga | Controllo |
|---|---|---|
| macOS | App predefinita per gli archivi — «ZIP, tar.gz, tar.xz, tar.zst, tar.bz2, tar, gz» | badge «Xipper» + «Cambia…» |
| | Estensione del Finder — «Menu contestuale e pulsante nella toolbar» | badge «Attiva» / «Non attiva» + «Apri Impostazioni di Sistema…» |
| | Quick Look e miniature — «Contenuto e rapporto di compressione con la barra spaziatrice» | badge |
| | Comandi Rapidi, Spotlight e Siri — elenco delle azioni | «Apri Comandi Rapidi» |
| | Icona nella barra dei menu | Toggle |
| Cartelle sorvegliate | elenco (nome · preset · pianificazione) + `plus` / `trash` — «Girano sugli E-core, con priorità bassa» | `+` → 8.6 |
| Terminale | Comando `xipper` — «Collegamento in /usr/local/bin allo stesso motore dell'app» | «Installa…» |

**Sezione «Agenti AI (MCP)» [non sul canvas]** (`point.3.connected.trianglepath.dotted`), nella stessa scheda Integrazioni, dopo Terminale:

| Riga | Controllo | Default |
|---|---|---|
| Consenti agli agenti AI di usare Xipper — «Server MCP `xipper mcp` per Claude Desktop, Claude Code e altri client» | Toggle | off |
| Cartelle consentite — «Gli agenti possono leggere e scrivere solo qui» | lista + `plus`/`trash` (`NSOpenPanel`, sola scelta di cartelle) | vuota |
| Solo lettura — «Gli agenti possono elencare, verificare e leggere, non estrarre né creare» | Toggle | on |
| Password per gli agenti — «Le password restano nel Portachiavi: l'agente vede solo un nome» | lista dei `password_ref` + «Aggiungi password…» (sheet con nome e `SecureField`) | — |
| Conferma le sovrascritture — «Ogni sovrascrittura chiede il tuo sì nel client» | badge «Sempre attivo» | — |
| Aggiungi a Claude Desktop | pulsante «Installa estensione…» (apre il `.mcpb`) | — |
| Aggiungi a Claude Code | pulsante «Copia comando» (copia `claude mcp add --transport stdio --scope user xipper -- …/xipper mcp`) | — |
| Registro attività — «Ultime operazioni degli agenti, senza password» | «Mostra registro…» (apre una `Table` letta da `~/Library/Logs/Xipper/mcp-audit.jsonl`) | — |

Quando il server è spento, tutte le righe tranne il Toggle sono disattivate. Il passaggio da Solo lettura a lettura e scrittura chiede conferma con `.confirmationDialog`: «Consentire agli agenti di estrarre e creare archivi nelle cartelle consentite?» · «Consenti» / «Annulla».

### Genomica [non sul canvas] (`testtube.2`)
| Sezione | Riga | Controllo | Default |
|---|---|---|---|
| BGZF | Usa BGZF per i file genomici — «.vcf, .bed, .gff/.gtf, .fa/.fasta, .fq/.fastq e .sam compressi in .gz restano indicizzabili da tabix e bcftools» | Toggle | on |
| | Livello BGZF — «Compatibile con `bgzip -l`» | Stepper 0–9 | 6 |
| | Crea l'indice .gzi — «Come `bgzip -i`» | Toggle | off |
| | Avvisa se un indice tabix non è più valido — «Dopo una ricompressione i .tbi/.csi vanno rigenerati» | Toggle | on |
| Archivi | Non ricomprimere i file genomici già compressi — «.bam, .cram, .bcf, .bgz, .vcf.gz, .fastq.gz, .sra e indici .bai/.crai/.tbi/.csi/.gzi» | Toggle (smart store) | on |
| Terminale | `xipper bgzip` — «Opzioni compatibili con bgzip: -c -d -i -l -@» | testo informativo | — |

Nell'inspector (3.1) e in Quick Look il formato si mostra come «BGZF». In 5.x la verifica BGZF riporta «Marker EOF presente» o l'errore relativo.

### 8.4 Prestazioni
| Sezione | Riga | Controllo | Default |
|---|---|---|---|
| Core | Lavori in primo piano — «Compressione ed estrazione avviate da te» | Picker | Tutti i P-core (N) |
| | Lavori in background — «Cartelle sorvegliate, Azioni rapide, Comandi Rapidi» | Picker | Solo E-core (N) |
| | Con l'alimentazione a batteria — «Limita il calore e i consumi» | Picker | Metà dei P-core |
| | Lavori contemporanei | Picker | 2 |
| Memoria e disco | Memoria massima per lavoro — «Finestre grandi di xz e zstd usano più RAM» | Picker | Automatica (4 GB) |
| | Usa cloni APFS quando possibile — «Copie istantanee per i file salvati senza compressione» | Toggle | on |
| Misurato su questo Mac | due barre opache: «Xipper · ZIP» 367 MB/s e «Utility Archivio» 49 MB/s | solo lettura | — |

Sotto le barre: «Ultimo archivio creato: …». N si legge dal sistema (`hw.perflevel0/1.physicalcpu`).

### 8.6 Sheet «Nuova cartella sorvegliata»
- Titolo **«Nuova cartella sorvegliata»**, «Ogni file che metti nella cartella viene archiviato da solo, anche con Xipper chiuso.»
- `Form` con le righe:
  - Cartella (pop-up con `folder.fill`);
  - Quando arriva un elemento («Comprimilo subito» / «Raccogli e comprimi ogni notte»);
  - Preset;
  - Password («Dal Portachiavi: …»);
  - Salva gli archivi in;
  - Dopo l'archiviazione — «Solo se la verifica dell'archivio riesce» («Sposta gli originali nel Cestino» / «Lascia gli originali»).
- Nota `cpu`: «Gira sugli E-core con priorità bassa: non rallenta il lavoro in primo piano.»
- Pulsanti: «Annulla» · **«Aggiungi»**.
- Il servizio che sorveglia le cartelle usa `FSEvents` ed è un agente avviato con `SMAppService`.

---

## 9. Onboarding — (1.1, 1.2, 1.3)

- **Finestra:** dedicata di 720×540 pt, senza toolbar, contenuto centrato. Si mostra al primo avvio e si può riaprire da Integrazioni.
- **Navigazione:** tre punti di pagina (7 pt) sopra i pulsanti. Transizione orizzontale (`.push(from: .trailing)`), dissolvenza con Riduci movimento. Pulsanti grandi (40 pt, `.controlSize(.large)`).

### 1.1 Benvenuto
- Icona dell'app a 96 pt, **«Benvenuto in Xipper»** (28 pt bold), «Comprimi, apri e verifica archivi ZIP, 7z e tar. Scritto per Apple Silicon, senza componenti esterni.» (Togliere «7z» finché non è supportato.)
- Tre righe, ciascuna con un simbolo a 28 pt in accent:

| Simbolo | Titolo | Testo |
|---|---|---|
| `bolt` | **Veloce davvero** | «Usa tutti i P-core: un archivio ZIP si crea fino a 7 volte più in fretta che con Utility Archivio.» |
| `lock` | **Sicuro di default** | «AES-256, password nel Portachiavi con Touch ID, protezione da zip-bomb e percorsi malevoli.» |
| `square.stack.3d.up` | **Dentro macOS** | «Finder, Quick Look, Comandi Rapidi e Spotlight. Spesso non serve nemmeno aprire l'app.» |

- Pulsante **«Continua»** (`.glassProminent`, largo 240).

### 1.2 Integra Xipper con il Mac
- Titolo **«Integra Xipper con il Mac»**, «Puoi cambiare tutto più tardi in Impostazioni › Integrazioni.»
- Riquadro opaco con 4 righe (simbolo 28 pt, titolo, descrizione, badge di stato, azione):

| Riga | Descrizione | Stato | Azione |
|---|---|---|---|
| Accesso alle cartelle | «Per estrarre accanto all'archivio e usare le cartelle sorvegliate. Scegli tu quali.» | badge verdi per cartella | «Consenti…» → `NSOpenPanel`, salvato come security-scoped bookmark |
| Estensione del Finder | «Comprimi, Estrai qui e Verifica nel menu contestuale e nella toolbar del Finder.» | «Non attiva» / «Attiva» | «Attiva…» → `FIFinderSyncController.showExtensionManagementInterface()`; lo stato si ricontrolla al ritorno in primo piano |
| Quick Look | «Premi la barra spaziatrice su un archivio per vederne il contenuto.» | «Attivo» | — |
| Comandi Rapidi e Spotlight | «Comprimi file, Estrai archivio, Verifica archivio, Elenca contenuto, Aggiungi password.» | «Disponibili» | — |

- Pulsanti: «Indietro» · **«Continua»** (si può proseguire senza permessi).

### 1.3 Apri gli archivi con Xipper
- Titolo **«Apri gli archivi con Xipper»**, «Con un doppio clic il Finder userà Xipper per i formati scelti.»
- Gruppo «Formati» con checkbox su due colonne: ZIP .zip · tar + gzip .tar.gz .tgz · tar + xz .tar.xz · tar + zstd .tar.zst · tar + bzip2 .tar.bz2 · tar .tar · gzip singolo .gz (off per default) · BGZF .bgz.
- Nota `info.circle`: «Utility Archivio resta installata: puoi tornare indietro da Impostazioni › Integrazioni o da Ottieni informazioni nel Finder.»
- Pulsanti: «Non ora» · **«Imposta come predefinita»**, che chiama `NSWorkspace.setDefaultApplication(at:toOpen:)` per ogni UTType scelto. Al termine → 2.1.

---

## 10. Estensioni — (9.1, 9.2, 9.3, 9.5)

Sono tutte interfacce di sistema: niente vetro personalizzato.

### 9.1 Finder (Finder Sync Extension)
- **Pulsante nella toolbar del Finder:** `archivebox` («Xipper»), che apre lo stesso menu.
- **Menu contestuale con file selezionati:**

| Voce | Note |
|---|---|
| Comprimi in ZIP | con l'icona dell'app; scorciatoia ⌥⌘Z |
| Comprimi in 7z | nascosta senza 7z |
| Comprimi con preset ▸ | Email · ZIP · parti da 25 MB / Lungo termine · 7z Ultra · AES / Backup veloce · tar.zst / — / Comprimi con opzioni… / Gestisci i preset… |
| Comprimi con BGZF | solo per file genomici |

- **Menu contestuale con un archivio selezionato:** Estrai qui · Estrai in… · Apri in Xipper · Verifica · Monta come volume · Converti in BGZF (solo .gz).
- Le azioni partono subito e mostrano l'HUD (o notifiche); nessuna finestra se non serve.

### 9.2 Quick Look di un archivio (Preview Extension, `QLPreviewingController`)
- **Intestazione** (vista opaca): nome, «3,05 GB · 2.418 elementi · AES-256» e quattro riquadri:

| Originale | Compresso | Formato | Cifratura |
|---|---|---|---|
| 4,62 GB | 3,05 GB · −34% | ZIP64 · Deflate (o BGZF) | `lock` AES-256 |

- **Albero:** `OutlineGroup` con Nome · Dimensione · Rapporto · Modificato.
- Riga in basso: `info.circle` «Barra spaziatrice su una voce per vederne l'anteprima · nessun file viene estratto».
- Pulsante «Apri con Xipper» (fornito dal sistema). Sola lettura, in streaming.

### 9.5 Miniature (Thumbnail Extension, `QLThumbnailProvider`)
- Foglio opaco 112×140 con raggio 12, `archivebox` al centro.
- Testi: numero di file in grassetto, dimensione in `.secondary`.
- Banda colorata in basso, alta 28, con il formato in maiuscolo («ZIP», «TAR.ZST», «GZ», «BGZF», «ZIP 3/3») e `lock` se cifrato. Colori: ZIP blu, tar teal, gz e BGZF grigio ardesia.
- Per 7z con nomi cifrati: «Nomi cifrati» al posto del numero.

### 9.3 Comandi Rapidi (App Intents)
| Azione | Parametri | Note |
|---|---|---|
| **Comprimi file** | File, Formato, Livello, Nome, Password (`AppEntity` sulle voci del Portachiavi: «Dal Portachiavi: …»), Preset | — |
| **Estrai archivio** | Archivio, Destinazione, Voci | — |
| **Verifica archivio** | Archivio | restituisce Esito ed Elenco errori; parametro «Se fallisce: Interrompi il comando» |
| **Elenca contenuto** | Archivio | restituisce nomi, dimensioni e rapporti |
| **Aggiungi password** | Archivio, Password | ricifra un archivio esistente |
| **Comprimi con BGZF** / **Converti in BGZF** | File | (STUDIO §4.4) |

Descrizione nella libreria: una riga in `.secondary` come nel canvas. Le stesse azioni compaiono in Spotlight e Siri tramite `AppShortcutsProvider`. Nomi e schemi sono allineati ai tool MCP (`archive_create`, `archive_extract`, `archive_test`, `archive_list`, `bgzf_*`).

---

## 11. Icona dell'app — (10.3)
- File `.icon` creato con Icon Composer, con due livelli:
  - Sfondo: gradiente blu, dall'alto a sinistra `#4AA3FF` al basso a destra `#0A57D4`;
  - Glifo: una X bianca con i denti della cerniera.
- Varianti generate dal sistema: chiaro, scuro (glifo blu su grafite), tinta, trasparente.
- Sotto i 32 pt i denti vanno tolti e resta solo la X. Nel canvas questa variante è descritta ma non ancora disegnata.

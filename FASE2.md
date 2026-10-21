# Xipper: fase 2 (app SwiftUI con Liquid Glass)

*Avviata il 21 ottobre 2026 · riferimenti: [docs/UI_SPEC.md](docs/UI_SPEC.md) e il canvas [Xipper — Flussi Liquid Glass](https://claude.ai/artifact/CspdHhiqFhGPGUY36aTxjs)*

## Progetto
- **`App/Xipper.xcodeproj`**, scritto a mano con i gruppi sincronizzati con le cartelle (formato Xcode 16+): un file nuovo in `App/Xipper/` entra nel target senza toccare il progetto. Nessun generatore esterno (XcodeGen/Tuist).
- **Target `Xipper` (app):** macOS 26, arm64, Swift 6 con strict concurrency, hardened runtime, **non sandboxed** (canale Developer ID, STUDIO.md §8 e §6-ter). Dipende da `XipperKit` tramite il pacchetto locale `..`.
- **Target `xipper-cli`:** compila gli stessi sorgenti di `Sources/xipper` e viene copiato in **`Xipper.app/Contents/Helpers/xipper`**. Non in `Contents/MacOS`: il file system non distingue le maiuscole e `xipper` sovrascriverebbe l'eseguibile `Xipper`. Per lo stesso motivo il target si chiama `xipper-cli`, con modulo `XipperCLI`.
- **Build:**

  ```bash
  xcodebuild -project App/Xipper.xcodeproj -scheme Xipper -derivedDataPath .build/xcode build
  ```

## Implementato (prima iterazione)

| Area | Stato |
|---|---|
| **Architettura** | `JobCenter` esegue create/extract/test di XipperKit in background, con progresso (MB/s, file corrente), annullamento, richiesta di password e conferma per le zip bomb. Durante i lavori è attivo `beginActivity(.userInitiated)`, così App Nap non congela l'avanzamento e il Mac non va in stop per inattività. `AppState` gestisce i file aperti da Finder e Dock e i Recenti di sistema. Le preferenze sono in `UserDefaults`. |
| **Home (2.1)** | Zona di rilascio opaca: tratteggio, che diventa pieno durante il trascinamento. Barra d'azione in `GlassEffectContainer`: capsula di vetro con Formato, Livello (Veloce/Normale/Massimo) e Password, più "Comprimi" `.glassProminent`. Un archivio rilasciato si apre nel browser; altri file vanno in coda per la compressione. Il nome di destinazione è automatico e unico (" 2"). |
| **HUD (7.1)** | Capsule di vetro in basso a destra, una per lavoro, con `glassEffectID` e una tinta solo semantica (rosso per errori, arancione per password e sicurezza). Azioni: Annulla, Dettagli, Mostra nel Finder, Password…, Estrai comunque (con una seconda conferma), Chiudi. |
| **Browser (3.1)** | `NavigationSplitView`: sidebar con l'albero delle cartelle; `Table` opaca con colonne Nome/Dimensione/Compresso/Rapporto/Modificato/🔒 e `scrollEdgeEffectStyle(.hard)`; doppio clic per entrare nelle cartelle; ricerca; toolbar con "Estrai" `.glassProminent` (⌥ = scegli la cartella), Verifica e Info. Inspector con i dettagli della voce o dell'archivio, informazioni BGZF e anteprima di testo e immagini tramite `Xipper.readEntry`. |
| **Password (2.3, 4.1, 4.3)** | Sheet di sistema: creazione con conferma, indicatore di robustezza e avviso sulle password non ASCII (7-Zip); apertura con l'avviso "Password errata". |
| **Report (5.1, 6.3)** | Banner di esito in vetro, tinto di rosso solo in caso di errori, e l'elenco delle voci fallite o saltate per sicurezza. |
| **Impostazioni (8.x)** | Generali, Formati, Sicurezza, Integrazioni (cartelle consentite per MCP, sola lettura, "Copia comando per Claude Code"), Genomica (BGZF, `.gzi`), Prestazioni (P-core ed E-core). |
| **Accessibilità** | "Riduci trasparenza" → `Glass.identity`; solo colori semantici. Verificato in modalità chiara e scura. |
| **Verifica visiva** | Catture delle sole finestre dell'app (CGWindowList + `screencapture -l`). Nelle build Debug ci sono agganci di avvio (`XIPPER_DEMO_CREATE/EXTRACT/TEST/DARK`) per fotografare gli stati senza automazione dell'interfaccia. |

## Checklist rispetto a UI_SPEC.md (prossime iterazioni)
- [x] **2.2:** lista dei file rilasciati in una `Table` (Nome · Tipo · Dimensione, cartelle con il numero di elementi calcolato in background), "Nome" modificabile con il suffisso dell'estensione, "Salva in" (cartella d'origine, Scrivania, Documenti, Download, Altra…), aggiungi/rimuovi in toolbar, riepilogo con i file del Mac esclusi, menu Formato con descrizioni e preset "Backup veloce" e "Archivio lungo termine". *Preset Email: manca il ZIP diviso in parti nel core.*
- [x] **2.4 / 2.5:** pannello di avanzamento in finestra, con morph dalla barra (`glassEffectID("job")`), velocità smussata su 1 s e aggiornata al massimo 4 volte al secondo, percentuale, byte, tempo stimato, file corrente, "Nascondi" verso l'HUD e "Annulla". Pannello di completamento con i riquadri opachi Dimensione / Tempo / Velocità media, nota sulla cifratura, Verifica · Mostra contenuto · **Mostra nel Finder** e "Crea un altro archivio". Errori e annullamento nello stesso pannello, con tinta rossa. *Badge "×Utility Archivio" e barre dei core: omessi finché il confronto non è misurato per il singolo lavoro.*
- [ ] **2.7:** opzione ZipCrypto con avviso, che richiede ZipCrypto in scrittura nel core. **2.6:** parti multiple, che richiedono ZIP multi-volume nel core.
- [ ] **2.8:** errore di disco pieno con tinta rossa, Riprova e "Salva altrove…".
- [ ] **7.1:** capsula compatta e unione (`glassEffectUnion`); `NSPanel` quando non ci sono finestre. *Avanzamento e badge sul Dock: fatti (beta2).* **7.2:** `MenuBarExtra`. *Notifiche: fatte (beta2).*
- [ ] **3.1:** sezioni Recenti/Preferiti/Preset nella sidebar; barra del percorso; barra di stato. *Trascinamento delle voci nel Finder e barra spaziatrice: fatti (beta2).*
- [x] **3.2:** sheet "Estrai N elementi": destinazione (accanto all'archivio, Download, Scrivania, Documenti, Altra…), struttura (cartelle / solo file), "Se un file esiste già" (Chiedi · Sostituisci · Mantieni entrambi · Salta), "Apri la cartella al termine", riquadro sulla quarantena. "Estrai" senza selezione = estrazione smart diretta; con una selezione o con ⌥ si apre lo sheet.
- [x] **3.3:** alert di sistema per il file esistente: riquadri archivio/disco con il badge "più recente", "Applica agli altri N conflitti" (conteggio da `plannedConflicts`), Mantieni entrambi (predefinito) · Sostituisci (sposta il file nel Cestino) · Salta. L'estrazione resta in pausa; HUD e sottotitolo del browser dicono "in pausa".
- [x] **3.4:** Quick Look della voce (beta2).
- [x] **4.2:** Portachiavi e Touch ID per le password degli archivi (beta2).
- [x] **5.2:** voci danneggiate nella finestra. **6.1–6.3:** avvisi di sicurezza secondo la specifica (verso la v1).
- [ ] **8.6:** cartelle sorvegliate. *1.1–1.3 onboarding: fatto (beta2).*
- [ ] **Estensioni:** FSKit (9.4). *Finder Sync (9.1, beta1), Quick Look dell'archivio (9.2), miniature (9.5) e Comandi Rapidi (9.3): fatti (beta2).*
- [x] Icona del design, String Catalog con l'inglese, aumento del contrasto e riduzione del movimento (verso la v1). *Resta il file `.icon` di Icon Composer per le varianti scura/tinta/trasparente.*

## Seconda iterazione (21/10/2026): 2.2, 2.4/2.5, 3.2, 3.3

**Core (XipperKit):**
- `OverwritePolicy.ask` con `ExtractOptions.conflictHandler`: le chiamate sono serializzate, "applica a tutti" viene ricordato, e l'estrazione aspetta la risposta.
- `trashReplacedFiles`: chi viene sostituito va nel Cestino.
- `flatten` ("solo i file"), `Xipper.plannedConflicts`, `Xipper.baseName` pubblico.
- 3 test nuovi (43 in totale).

**xz più veloce ai livelli alti.** liblzma usa blocchi da 3 volte il dizionario (192 MiB a -9): su input normali i blocchi sono troppo pochi per tenere occupati i core, e l'avanzamento resta fermo per decine di secondi. Misure sul corpus da 468 MB:

| xz -9 | Tempo | Dimensione |
|---|---|---|
| default liblzma (3× dizionario) | 56,5 s | 122,6 MB |
| 1× dizionario | 24,9 s | 124,8 MB |
| **2× dizionario (scelto per -9)** | **50,9 s** | **120,4 MB** |

Ai livelli -7 e -8 si usa 1× dizionario, privilegiando la velocità.

**App:**
- `ItemScanner` calcola dimensioni, file e file del Mac esclusi;
- `JobPanel` e `ExtractSheet`;
- `ConflictPrompt`: un `NSAlert` sul main thread, mentre il thread di estrazione resta in attesa;
- velocità smussata che resiste alle pause degli encoder;
- i lavori "in primo piano" non vengono ripetuti nell'HUD;
- nuovi agganci di debug (`XIPPER_DEMO_ITEMS`, `XIPPER_DEMO_FORMAT`, `XIPPER_DEMO_COMPRESS`, `XIPPER_DEMO_EXTRACT_SHEET`, `XIPPER_DEMO_CONFLICT`), verificati con catture delle finestre (compresi alert e sheet).

## Beta1 (0.9.0-beta1, 21/10/2026)

| Area | Stato |
|---|---|
| **Firma** | Identità self-signed "Xipper Self-Signed" in un portachiavi dedicato (`scripts/create-signing-identity.sh`): il portachiavi di login e le impostazioni di attendibilità restano intatti, e la chiave sta in `~/.xipper-signing` (fuori dal repo). Firma dall'interno verso l'esterno con hardened runtime: CLI, estensione (con entitlement sandbox), app. Gatekeeper rifiuta la beta perché non è notarizzata: i tester usano "Apri comunque" (vedi [docs/BETA_TESTERS.md](docs/BETA_TESTERS.md)). |
| **Release** | `scripts/release.sh beta1` esegue build Release, firma, verifica, DMG (UDZO, con link ad Applicazioni e note per i tester) e SHA-256 → `dist/` (escluso da git). |
| **Icona** | Generata da `scripts/make-app-icon.swift` (asset catalog, tutte le dimensioni). Da rifare in Icon Composer con i livelli in vetro. |
| **Azioni rapide (Servizi)** | "Comprimi con Xipper", "Estrai con Xipper", "Verifica con Xipper" (`NSServices`), verificate con `NSPerformService`. |
| **Finder Sync extension** | Target `XipperFinder.appex`, sandboxed: sottomenu "Xipper" (Comprimi / Estrai qui / Verifica / Apri in Xipper) e pulsante in toolbar. Passa la selezione all'app con `xipper://`. Verificata con la firma self-signed: registrata, attivata, processo avviato dal Finder, poi disattivata. |
| **Schema `xipper://`** | compress / extract (smart) / test / open: crea solo file nuovi, non sovrascrive mai. |
| **Errori (2.8)** | Nuovo errore di core `insufficientSpace`, con controllo preventivo prima di estrarre (prima veniva scambiato per una zip bomb). Classificazione disco pieno / permessi / sola lettura / volume scollegato; pannello con "Riprova" e "Salva altrove…". Provato su un volume da 16 MB: il file parziale viene eliminato e gli originali restano intatti. |
| **Annullamento** | Bug trovato dai nuovi test: tar.xz/zst ignoravano l'annullamento durante la fase finale dell'encoder. Ora il token arriva agli encoder e liblzma MT usa un timeout di 250 ms. |
| **Test** | 46 test più `zip64OverFourGiB` (voce da 4,5 GiB, deflate e store, verificata da 7-Zip; attivo solo con `XIPPER_BIG_TESTS=1`). |
| **Versioni** | App ed estensione 0.9.0 (build 1); CLI e server MCP 0.9.0. |

## Beta2 (0.9.0-beta2, 21/10/2026)

| Area | Stato |
|---|---|
| **Quick Look dell'archivio (9.2)** | `XipperPreview.appex` (`QLPreviewingController`, sandbox): intestazione con formato, dimensioni e numero di elementi, poi l'elenco delle voci (al massimo 500 righe; tar letti fino a 2 GiB). Verificata con `qlmanage -p` su un tar.zst. |
| **Miniature (9.5)** | `XipperThumbnail.appex` (`QLThumbnailProvider`): scatola con l'etichetta del formato e, per gli ZIP, il numero di file. Verificata con `QLThumbnailGenerator` su ZIP e tar.zst. |
| **Quick Look della voce (3.4)** | Barra spaziatrice o "Anteprima" nel browser: le voci selezionate vengono estratte in una cartella temporanea (estrazione sicura normale) e aperte nel pannello Quick Look di sistema, che segue la selezione. La cartella viene svuotata all'avvio e all'uscita. |
| **Trascinamento nel Finder** | Le righe del browser forniscono un file "pigro" (`NSItemProvider.registerFileRepresentation`): l'estrazione parte solo al rilascio. Da provare a mano. |
| **Portachiavi e Touch ID (4.2)** | Opzione "Ricorda nel Portachiavi" nello sheet della password (apertura e creazione). La password viene salvata nel portachiavi di login solo dopo che il lavoro è riuscito, una per archivio (percorso reale). Per usarla serve Touch ID o la password del Mac (`LAContext`, disattivabile in Impostazioni › Sicurezza, dove si possono anche dimenticare tutte). Una password salvata che risulta errata viene cancellata. Salvataggio, lettura e cancellazione provati con un servizio di test; il prompt Touch ID va provato a mano. |
| **Notifiche e Dock (7.1, 7.2)** | Notifica a fine lavoro solo se Xipper non è in primo piano (autorizzazione provvisoria, senza richiesta); il clic mostra il risultato nel Finder. Icona del Dock con la barra di avanzamento complessiva, badge con il numero di lavori o "!" se uno aspetta una risposta. |
| **Onboarding (1.1–1.3)** | Al primo avvio (e da Aiuto › Introduzione a Xipper): attivazione dell'estensione Finder, Xipper come app predefinita per gli archivi (conferma del sistema) e comando `xipper` nel Terminale (collegamento in `/opt/homebrew/bin` se scrivibile, altrimenti il comando `sudo ln` copiato negli appunti). |
| **Comandi Rapidi (9.3)** | App Intents "Comprimi con Xipper" (file, formato, nome → archivio), "Estrai con Xipper" (archivio, destinazione, password → cartella) e "Verifica con Xipper" (→ Sì/No con messaggio). Usano il Portachiavi se c'è una password salvata. Metadati generati; da provare nell'app Comandi Rapidi. |
| **Release** | `scripts/xcodeproj_add_extension.py` aggiunge un target di estensione al progetto; `scripts/release.sh` firma ogni `.appex` con il proprio file di entitlement. DMG 4,2 MB. |

## Verso la v1 (21/10/2026): voci danneggiate, avvisi di sicurezza, accessibilità, inglese, icona

| Area | Stato |
|---|---|
| **Core: cause strutturate** | `SkippedEntry.problem` descrive ogni voce saltata o danneggiata: percorso fuori destinazione, symlink esterno, scrittura attraverso un symlink, CRC con valori atteso/letto (nuovo errore `checksumMismatch`), dati troncati con i byte letti (`truncated`), autenticazione AES, marcatore EOF mancante. `reason` resta il testo tecnico inglese per CLI e MCP. |
| **Core: "estrai comunque" con limite** | `ExtractionLimits.stopAtLimit` estrae fino a `maxTotalBytes` e poi si ferma, eliminando quanto scritto; `minFreeFraction` lascia libero almeno il 10% del volume. 3 test nuovi (49 in tutto). |
| **5.2 Voci danneggiate** | Nella finestra dell'archivio, al posto del contenuto: banner di vetro rosso ("N voci danneggiate su M", tempo, nessun dato scritto), filtro Tutte / Solo errori, tabella Voce · Dimensione · Problema · Esito, "Esporta rapporto…", "Estrai voci integre…" (sheet 3.2 con le voci integre già selezionate, solo per ZIP), nota su PAR2. "Torna al contenuto" e "Verifica di nuovo". Dall'HUD, "Dettagli" apre la finestra dell'archivio in questa vista. |
| **6.1 Zip-bomb** | Alert di sistema critico appena scatta il controllo: peso dell'archivio, dati dichiarati, rapporto, spazio libero; Non estrarre (predefinito) · Sposta nel Cestino · Estrai comunque…. |
| **6.2 Seconda conferma** | Pannello da 470 pt: limite 1 / 10 / 50 GB, cartella nuova in Download, "Fermati se resta meno del 10%" sempre attivo; "Estrai fino a N" (rosso) · **Annulla** (predefinito). Al limite il lavoro fallisce con "i dati scritti sono stati eliminati". Da provare a mano (serve un clic). |
| **6.3 Elementi bloccati** | Finestra aperta a fine estrazione se ci sono voci rifiutate: banner arancione, tabella Voce · Motivo · Dove avrebbe scritto, "Copia rapporto", "Mostra nel Finder", righe su elementi estratti, quarantena e assenza di "estrai comunque". Verificata con un archivio con `../../.zshrc`, `driver/../../../Library/LaunchAgents/x.plist` e un symlink a `/etc/passwd`: nulla scritto fuori. |
| **Accessibilità (0.3, 10.1, 10.2)** | `accessibleGlass`: con Riduci trasparenza o Aumenta contrasto il vetro personalizzato diventa una superficie piena con bordo (1,5 pt `.primary` con contrasto aumentato). Con Riduci movimento i morph diventano dissolvenze da 150 ms e niente rimbalzi o pulsazioni dei simboli. Zona di rilascio con azione VoiceOver "Scegli i file", icone decorative nascoste, `.help` sui pulsanti solo icona. |
| **Inglese** | String Catalog (`Localizable.xcstrings`) in app ed estensioni, lingua sorgente italiano, 366 stringhe con l'inglese e i plurali singolare/plurale in entrambe le lingue. I testi AppKit (alert, pannelli, notifiche, menu del Finder) passano da `String(localized:)`. `scripts/sync-strings.sh` aggiorna i cataloghi dopo una build da riga di comando; `scripts/translations-en.py` contiene le traduzioni e segnala quelle mancanti. Restano in italiano i nomi dei Servizi in Info.plist. |
| **Icona** | Quella del design (A3): X bianca con i denti della cerniera su gradiente #4AA3FF → #0A57D4; sotto i 32 pt solo la X. Generata da `scripts/make-app-icon.swift`. |

## Aggiornamenti manuali (21/10/2026)

Come in Neko e Underdock, senza Sparkle e senza installazioni automatiche:
- **Controllo:** all'avvio (build Release), al massimo una volta al giorno e disattivabile in Impostazioni › Generali; oppure **Xipper › Cerca aggiornamenti…**, che risponde anche quando non c'è niente di nuovo. Ogni versione viene annunciata in automatico una volta sola.
- **Feed:** `api.github.com/repos/nicolorisitano82/xipper/releases`. Le pre-release vengono proposte solo a chi usa una beta; il confronto tra versioni capisce `0.9.0-beta10 > 0.9.0-beta9` e `0.9.0 > 0.9.0-beta2`. `release.sh` scrive `XipperReleaseVersion` (per esempio `0.9.0-beta2`) nell'Info.plist.
- **Download:** solo da GitHub in HTTPS. Il DMG viene confrontato con il file `.dmg.sha256` del rilascio (se non corrisponde viene eliminato) e poi messo nei Download.
- **Installazione:** "Apri e chiudi Xipper" apre l'immagine ed esce (se ci sono lavori in corso, prima lo chiede); il trascinamento in Applicazioni resta manuale. In alternativa, "Mostra nel Finder" o "Più tardi".
- **Verifica:** confronto delle versioni, lettura del feed reale (da 0.9.0-beta1 propone la beta2; dalla beta2 e dalla 0.9.0 nessuna proposta), host fidati e impronta SHA-256 del DMG della beta2, con uno script separato. Proposta, download e verifica dell'impronta provati nell'app con `XIPPER_DEMO_VERSION=0.9.0-beta1`.

## Verso la v1: secondo controllo dello studio (21/10/2026)

| Voce dello studio | Stato |
|---|---|
| ZIP multi-volume in lettura (§4.2) | **Fatto.** `FileReader` legge più file come uno solo; `ZipArchive` riconosce le parti PKZIP/Info-ZIP (`.z01`…`.zip`, offset per disco, anche nei campi ZIP64) e i pezzi 7-Zip/`split` (`.zip.001`…). L'archivio si apre da qualunque parte; una parte mancante è un errore chiaro. 3 test, anche contro `zip -s`. |
| Voci sovrapposte nella directory centrale (§7.2) | Già presente (`checkOverlaps`): l'archivio viene rifiutato come danneggiato. |
| Manifest `SHA256SUMS` (§7.5, schermata 5.1) | **Fatto.** `Xipper.test(…, digests: true)` calcola lo SHA-256 di ogni file nello stesso passaggio (ZIP in parallelo, tar in streaming, file singolo compresso); `TestReport.sha256sums` nel formato di `shasum -c`. Nell'app: "Esporta SHA256SUMS…" nell'esito positivo della verifica; nella CLI: `xipper test --sha256`. 3 test contro `shasum`. |
| App Intents "Elenca contenuto" (§6) | **Fatto.** Restituisce i percorsi dei file. |
| CRC32 hardware (§5.2), nomi CP437 (§4.3) | Già presenti (libdeflate con `PMULL`/`CRC32X`; decodifica CP437). |
| Apple Archive, lz4, brotli in lettura (§4.2) | **Rimandati** a dopo il merge del 7z, che modifica lo stesso `ArchiveFormat`. |
| Developer ID e notarizzazione | Dipende dall'iscrizione all'Apple Developer Program. |

## Chiusura della V1: robustezza e metadati del Mac (21/10/2026)

| Voce | Stato |
|---|---|
| **Fuzzing (§7.6)** | `FuzzTests`: archivi validi dei 10 formati vengono mutati (byte invertiti, troncamenti, campi a 0xFF/0x00, porzioni duplicate o cancellate) e passano da detect, list, test ed extract con un limite di 64 MB. Si accetta qualsiasi esito tranne crash, blocco o scrittura fuori destinazione. 60 mutazioni per formato nella suite normale; `XIPPER_FUZZ_ITERATIONS=3000` per i giri lunghi. |
| **Bug trovato dal fuzzing** | BGZF: un `XLEN` alterato più lungo del blocco faceva crollare il programma (`Range requires lowerBound <= upperBound`) in list, test ed extract. Ora è un errore "archivio danneggiato". Il giro lungo (3000 × 10 formati) passa. |
| **Attributi estesi nei tar (§4.3)** | Tag e informazioni del Finder, resource fork, commenti di Spotlight: scritti come record pax `LIBARCHIVE.xattr.*` (base64) e `SCHILY.xattr.*` (binari), come fa bsdtar, e ripristinati in estrazione (file e cartelle, via descrittore). Quarantena, provenance e attributi di sicurezza non viaggiano mai. Opzioni `CreateOptions.storeExtendedAttributes` ed `ExtractOptions.restoreExtendedAttributes`, attive di default. `tar --xattrs` di macOS li legge. |
| **AppleDouble (`._nome`, `__MACOSX/`)** | Gli ZIP del Finder ("Comprimi") e i tar di macOS mettono i metadati in file AppleDouble. In estrazione Xipper li riapplica ai file (Finder info, resource fork, attributi estesi), come Utility Archivio, invece di lasciare `__MACOSX` e `._` nella cartella; browser, Quick Look e miniature non li mostrano. Provato con `ditto -c -k --sequesterRsrc` e con `tar` di macOS. |
| **Barra dei menu (7.2)** | `MenuBarExtra` facoltativo (Impostazioni › Integrazioni): lavori con barra e Annulla, "Apri Xipper", "Impostazioni…". |
| **Azioni nelle notifiche (7.2)** | "Archivio creato": Mostra nel Finder, Verifica. "Verifica non riuscita": Mostra rapporto, che apre le voci danneggiate nella finestra dell'archivio. |
| **Roadmap** | Nella v2, come punto principale, le ottimizzazioni in assembler ARM64/NEON (e GPU dove misurabile) sui punti caldi. |

## Stato della V1 e cosa manca (21/10/2026)

**Fatto:** UI con Liquid Glass (crea, estrai, sfoglia, verifica, password), Finder Sync, Azioni rapide, Quick Look e miniature, Comandi Rapidi (comprimi, estrai, verifica, elenca), Portachiavi e Touch ID, notifiche con azioni, Dock, barra dei menu, onboarding, aggiornamenti manuali, inglese, accessibilità, avvisi di sicurezza, voci danneggiate, SHA256SUMS, ZIP divisi, attributi estesi e AppleDouble, fuzzing; Genomica 1.7 unita.

**Test:** il blocco intermittente della suite era nell'helper `run()` dei test, che scriveva lo stdin del processo figlio prima di avviarlo e di leggerne l'output (si fermava nel test end-to-end del server MCP, circa 1 giro su 20). Ora lo stdin viene scritto su un altro thread mentre si legge l'output.

**Per chiudere la V1:**
1. **7z** (fase 3 della roadmap, ma nella matrice dei formati è ✅ v1): pronto sul branch `claude/gifted-greider-c8e9b6`, con decodifica LZMA/LZMA2 in assembler ARM64; da unire.
2. Dopo il 7z: **Apple Archive (`.aar`), CPIO, lz4 e brotli** in lettura (matrice §4.2), che toccano lo stesso `ArchiveFormat`.
3. **Attributi estesi negli ZIP creati da Xipper** (AppleDouble `__MACOSX/` solo su richiesta, come dice lo studio §4.3).
4. **Specifica UI ancora aperta:** 3.1 (Recenti/Preferiti nella barra laterale, barra del percorso, barra di stato), 7.1 (capsula compatta e `NSPanel` senza finestre), 2.7 (ZipCrypto in scrittura con avviso).
5. **Benchmark ripetibili** (§5.4), che servono anche alla fase 0 del nuovo formato.
6. **Icona `.icon`** di Icon Composer per le varianti scura, tinta e trasparente.
7. **Developer ID e notarizzazione:** dipendono dall'iscrizione all'Apple Developer Program.

**Studio del nuovo formato:** [docs/reports/Nuovo formato di compressione Xipper.md](docs/reports/Nuovo%20formato%20di%20compressione%20Xipper.md), con gli appunti della ricerca in `docs/research_notes/`.

## Chiusura della V1: 7z, formati in lettura, ZipCrypto, browser (21/10/2026)

| Voce | Stato |
|---|---|
| **7z unito** | Branch `claude/gifted-greider-c8e9b6` unito a main (conflitti risolti in `Xipper.swift`, CLI e documenti). Nell'app: formato nel menu (con descrizione "compatto, nomi cifrati"), tipi di documento, Servizi, Quick Look, miniature, app predefinita, Comandi Rapidi; impostazioni 7z (solid, cifra i nomi). Un 7z con nomi cifrati mostra "Nomi dei file cifrati" e chiede la password (anche dal Portachiavi) prima di elencare il contenuto. Il fuzzing copre anche il 7z. |
| **lz4 e brotli in lettura** | `LZ4FrameDecoder` (formato frame: blocchi indipendenti e collegati, frame skippable, checksum xxHash32 di blocco e contenuto) e `BrotliDecoder` (Compression di sistema), dentro la pipeline di decompressione: `.lz4`, `.tar.lz4`, `.br`, `.tar.br`. |
| **CPIO e Apple Archive in lettura** | `CpioReader` (newc, crc, odc, anche dentro gzip/xz/zstd…) e `AppleArchiveReader` (LZFSE, LZMA, LZ4, zlib, raw, tramite il framework di sistema) producono voci come il lettore tar, quindi passano dalla stessa estrazione sicura. `ArchiveFormat.canCreate` è falso per questi formati. |
| **ZipCrypto in scrittura (2.7)** | Su richiesta, con l'avviso della specifica nello sheet della password (Usa ZipCrypto · Usa AES-256). Voci scritte con data descriptor e byte di controllo dall'ora DOS, come Info-ZIP; lette da `unzip` e 7-Zip. |
| **Attributi del Mac negli ZIP** | Opzione "Salva tag e attributi del Mac": file AppleDouble in `__MACOSX/` come il Finder; `ditto -x -k` ripristina attributi e resource fork. Disattivata di default (ZIP puliti per Windows). |
| **Browser (3.1)** | Preferiti (stella nella toolbar) e Recenti nella barra laterale, barra del percorso cliccabile, barra di stato ("1 di 1.206 selezionati · 1,21 GB in Documenti"), doppio clic su un file → Quick Look. |
| **HUD (7.1)** | Con tre o più lavori la pila diventa una capsula con anello di avanzamento, "3 lavori", "46% · 5 s"; un clic la espande. Senza finestre aperte (azioni dal Finder) l'HUD appare in un pannello flottante non attivante in basso a destra. |
| **Test** | 99 test, tutti verdi: 6 sui formati in lettura (contro `lz4`, `brotli`, `cpio`, `aa`), ZipCrypto contro `unzip` e 7-Zip, AppleDouble contro `ditto`; fuzzing anche su lz4, brotli, cpio e Apple Archive (800 mutazioni per formato senza crash). |

**Benchmark ripetibili (§5.4):** `scripts/benchmark.sh [MB] [esecuzioni]` genera un corpus deterministico (sorgenti, testi, dati già compressi, un file grande) e confronta Xipper con ditto, Info-ZIP, `tar | zstd` e 7-Zip; risultati in [docs/BENCHMARK.md](docs/BENCHMARK.md). Su M3 Max, 316 MB: ZIP in 0,33 s contro 6,57 s di ditto (circa 20×) e 5,48 s di Info-ZIP; tar.zst 5× più veloce di `tar | zstd -T0`; 7z 3,5× più veloce di `7zz -mx5` con un rapporto quasi uguale; verifica ZIP 0,09 s contro 1,78 s di `unzip -t`; estrazione ZIP 4× più veloce di ditto. L'obiettivo dello studio ("ZIP almeno 4× Utility Archivio") è superato.

**Resta per la V1:** Developer ID con notarizzazione, che dipende dall'iscrizione all'Apple Developer Program.

## Chiusura della V1: CPIO e Apple Archive in scrittura, dettagli UI, inglese, icona (21/10/2026)

| Voce | Stato |
|---|---|
| **Apple Archive in scrittura** | `AppleArchiveWriter` sul framework di sistema: LZ4 (Veloce), LZFSE (Normale), LZMA (Massimo); attributi estesi nel campo XAT (prima dei dati, così il lettore li ha prima di scrivere il file); con la password, archivio **AEA** cifrato (profilo scrypt + AES-CTR + HMAC) che `aea decrypt` apre. macOS rifiuta le password AEA sotto i 20 byte ("Password is too short", anche con `aea encrypt`): errore chiaro nel core e requisito nello sheet. Il lettore apre anche gli AEA e ricostruisce gli attributi (blob XAT decodificato da noi, perché l'API non li espone). |
| **CPIO in scrittura** | `CpioWriter` in formato newc (file fino a 4 GiB, symlink, padding a 512 come `cpio(1)`); `cpio -idm` lo estrae. |
| **Inspector (3.1)** | CRC-32 della voce (ZIP e 7z, in monospazio), permessi in monospazio, SHA-256 dell'archivio calcolato in background, riga Quarantena ("Sì, scaricato con Safari" dall'attributo `com.apple.quarantine`), pulsante "Verifica archivio". |
| **Esito della verifica (5.1)** | "Tutte le N voci sono integre", tempo e velocità, filtro Tutte / Solo errori, tabella Voce · Dimensione · CRC-32 · Esito, "Esporta SHA256SUMS…" e "Fine". |
| **Pausa (7.1)** | `CancellationToken.pause()/resume()`: i worker si fermano al controllo successivo; nell'HUD Pausa/Riprendi e "In pausa". |
| **Preset nella barra laterale (3.1)** | Condivisione (ZIP), Backup veloce (tar.zst), Archivio lungo termine (tar.xz), Riservato (7z): un clic imposta formato e livello e apre "Nuovo archivio". |
| **Inglese** | `README.en.md` e `docs/BETA_TESTERS.en.md`, con link fra le lingue; il DMG contiene "LEGGIMI - beta.md" e "README - beta.md". |
| **Icona (10.3)** | `App/Xipper/AppIcon.icon` (Icon Composer): gradiente #4AA3FF → #0A57D4 e glifo X con la cerniera in SVG; macOS ne ricava le varianti scura, tinta e trasparente, Xcode anche l'`.icns` di riserva. Generato da `scripts/make-app-icon.py`; il vecchio asset PNG è stato rimosso. Il glifo semplificato sotto i 32 pt resta da fare a mano in Icon Composer. |
| **Test** | 102 test, tutti verdi, compresi Apple Archive contro `aa` e `aea`, CPIO contro `cpio`. |

## Formato XIZ in BETA (21/10/2026)

Prima fase del [nuovo formato](docs/reports/Nuovo%20formato%20di%20compressione%20Xipper.md), estensione `.xiz`, tipo `app.xipper.xiz` dichiarato dall'app.

| Voce | Stato |
|---|---|
| **Layout v0** | Superblock da 64 B (magic, versione 0.1, id casuale, CRC-32C) · frame (header da 32 B + payload) · catalogo zstd · footer fisso da 96 B (offset e dimensioni del catalogo, conteggi, totale dichiarato, SHA-256 del catalogo, CRC-32C, magic finale). Codice in `Sources/XipperKit/Xiz/`. |
| **Frame** | Indipendenti, fino a 4 MiB di dati: i file piccoli condividono i frame, quelli grandi si dividono; zstd (livello 1 Veloce, 3 Normale, 19 Massimo) oppure store se non comprime. CRC-32C (istruzioni ARMv8) del payload nel header e nel catalogo. Compressione parallela a finestre di 2× i worker, scrittura in ordine. |
| **Deduplicazione** | Per file intero: si calcola lo SHA-256 solo dei file con dimensione uguale a un altro; le copie puntano agli stessi frame. Sulla cartella di prova (sorgenti duplicati e un file casuale da 20 MB copiato) l'archivio è 20,2 MB contro 40,2 MB di tar.zst e 40,4 MB di ZIP. |
| **Metadati** | Tipo, percorso, permessi, uid/gid, mtime in nanosecondi, symlink, attributi estesi (tag del Finder, resource fork). |
| **Sicurezza** | Il catalogo è l'unica fonte di verità: frame in ordine stretto senza sovrapposizioni né buchi, estensioni dentro i frame e somma uguale alla dimensione dichiarata, totale nel footer controllato contro lo spazio libero prima di scrivere, header di ogni frame confrontato con il catalogo, decompressione alla dimensione esatta; estrazione tramite `ExtractionContext` (zip-slip, symlink, quarantena). |
| **Verifica** | Tutti i frame in parallelo (header, CRC-32C, decompressione); con `--sha256` anche lo SHA-256 di ogni file. Un byte alterato viene indicato come CRC non corrispondente; un archivio troncato o con il catalogo alterato viene rifiutato. |
| **Nell'app** | Impostazioni › Generali › Funzioni sperimentali › "Formato XIZ": compare nel menu dei formati come "XIZ · BETA". L'apertura dei `.xiz` funziona sempre (browser, Quick Look, miniature). Senza password: la cifratura è la fase 2. |
| **Test** | 3 test dedicati e fuzzing (3000 mutazioni senza crash), più round trip con selezione, attributi, anteprima delle voci. |
| **Non ancora (fasi 2–7)** | Cifratura (Argon2id, AES-GCM per frame, catalogo STREAM), dizionari ZDICT, ordinamento per similarità, FastCDC, append, dati di recupero, ottimizzazioni ARM64/Metal, specifica pubblica e lettore di riferimento. Il layout può cambiare prima della v1. |

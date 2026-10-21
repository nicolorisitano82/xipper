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
- [ ] **7.1:** capsula compatta e unione (`glassEffectUnion`); `NSPanel` quando non ci sono finestre; avanzamento e badge sull'icona del Dock. **7.2:** notifiche (`UNUserNotificationCenter`) e `MenuBarExtra`.
- [ ] **3.1:** sezioni Recenti/Preferiti/Preset nella sidebar; barra del percorso; barra di stato; trascinamento delle voci nel Finder (promessa di file); barra spaziatrice → 3.4.
- [x] **3.2:** sheet "Estrai N elementi": destinazione (accanto all'archivio, Download, Scrivania, Documenti, Altra…), struttura (cartelle / solo file), "Se un file esiste già" (Chiedi · Sostituisci · Mantieni entrambi · Salta), "Apri la cartella al termine", riquadro sulla quarantena. "Estrai" senza selezione = estrazione smart diretta; con una selezione o con ⌥ si apre lo sheet.
- [x] **3.3:** alert di sistema per il file esistente: riquadri archivio/disco con il badge "più recente", "Applica agli altri N conflitti" (conteggio da `plannedConflicts`), Mantieni entrambi (predefinito) · Sostituisci (sposta il file nel Cestino) · Salta. L'estrazione resta in pausa; HUD e sottotitolo del browser dicono "in pausa".
- [ ] **3.4:** Quick Look della voce.
- [ ] **4.2:** Portachiavi e Touch ID per le password degli archivi.
- [ ] **5.2:** voci danneggiate *nella finestra*. **6.1–6.3:** avvisi di sicurezza secondo la specifica (alert di sistema, seconda conferma, elementi bloccati nella finestra).
- [ ] **8.6:** cartelle sorvegliate. **1.1–1.3:** onboarding (estensione Finder, app predefinita).
- [ ] **Estensioni:** Finder Sync (9.1), Quick Look dell'archivio (9.2), miniature (9.5), App Intents / Comandi Rapidi (9.3), FSKit (9.4).
- [ ] **Icona** (Icon Composer, 10.3); localizzazione con String Catalog; aumento del contrasto e riduzione del movimento (10.1, 10.2).

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

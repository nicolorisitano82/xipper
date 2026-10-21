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
- [ ] **2.2:** dopo il rilascio, lista dei file in una `Table` con "Nome" modificabile, "Salva in", aggiungi/rimuovi e riepilogo; preset (Email / Backup veloce).
- [ ] **2.4 / 2.5:** pannello di avanzamento *nella finestra*, con morph da zona e barra (`glassEffectID("job")`), velocità grande smussata, tempo stimato, file corrente, "Nascondi" verso l'HUD; pannello di completamento con i tre riquadri e le azioni.
- [ ] **2.7:** opzione ZipCrypto con avviso, che richiede ZipCrypto in scrittura nel core. **2.6:** parti multiple, che richiedono ZIP multi-volume nel core.
- [ ] **2.8:** errore di disco pieno con tinta rossa, Riprova e "Salva altrove…".
- [ ] **7.1:** capsula compatta e unione (`glassEffectUnion`); `NSPanel` quando non ci sono finestre; avanzamento e badge sull'icona del Dock. **7.2:** notifiche (`UNUserNotificationCenter`) e `MenuBarExtra`.
- [ ] **3.1:** sezioni Recenti/Preferiti/Preset nella sidebar; barra del percorso; barra di stato; trascinamento delle voci nel Finder (promessa di file); barra spaziatrice → 3.4.
- [ ] **3.2:** sheet "Estrai N elementi". **3.3:** conflitto con un file esistente. **3.4:** Quick Look della voce.
- [ ] **4.2:** Portachiavi e Touch ID per le password degli archivi.
- [ ] **5.2:** voci danneggiate *nella finestra*. **6.1–6.3:** avvisi di sicurezza secondo la specifica (alert di sistema, seconda conferma, elementi bloccati nella finestra).
- [ ] **8.6:** cartelle sorvegliate. **1.1–1.3:** onboarding (estensione Finder, app predefinita).
- [ ] **Estensioni:** Finder Sync (9.1), Quick Look dell'archivio (9.2), miniature (9.5), App Intents / Comandi Rapidi (9.3), FSKit (9.4).
- [ ] **Icona** (Icon Composer, 10.3); localizzazione con String Catalog; aumento del contrasto e riduzione del movimento (10.1, 10.2).

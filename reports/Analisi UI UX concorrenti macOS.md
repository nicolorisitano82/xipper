# Analisi UI/UX dei concorrenti macOS per Xipper

*Ricerca web del 31 ottobre 2026. Le fonti sono citate inline. Quando un'informazione viene da un sito di un vendor o da un blog SEO lo segnalo; i punti non verificati sono marcati **(non verificato)**.*

> Limiti della ricerca: Reddit non è raggiungibile in fetch diretto e i motori di ricerca non hanno restituito thread r/macapps o Hacker News pertinenti. Il "sentiment Reddit" qui sotto arriva da un riassunto di terze parti ([community.ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733)). Le recensioni utente più ricche e concrete sono quelle di **Setapp** (BetterZip, Archiver) e del **Mac App Store** (Keka, The Unarchiver). Diversi articoli "best of 2026" (compresto.app, setapp.com, macpaw.com) sono di vendor concorrenti, quindi parziali.

---

## 1. Tabella comparativa

| App (versione attuale) | Modello d'uso principale | Avvio compressione / estrazione | Browse e anteprima contenuti | Modifica in place | Password / cifratura | Progress e coda | Default notevoli | Prezzo |
|---|---|---|---|---|---|---|---|---|
| **Keka** 1.6.x ([keka.io](https://www.keka.io/en/)) | Finestrella "drop target" più icona nel Dock | Drop su icona Dock o finestra, Finder extension ("Compress to", "Compress to Here"), doppio clic sull'archivio ([Macworld](https://www.macworld.com/article/614130/keka-review.html)) | Nessun browser, non pensato per vedere prima di estrarre ([Setapp](https://setapp.com/app-reviews/winzip-alternatives-for-mac)) | No | AES-256 su 7z/ZIP, header cifrati per 7z; opzione "chiedi sempre la password" ([App Store](https://apps.apple.com/us/app/keka/id470158793)) | Più task in parallelo con colori distinti e stima del tempo ([How-To Geek](https://tech.yahoo.com/articles/macos-bad-unzipping-files-heres-173015069.html)) | "Escludi risorse Mac" (.DS_Store, `__MACOSX`, `._`) attivo di default ([Uni Hamburg](https://www.ew.uni-hamburg.de/service/digitale-arbeit/anleitungen/howtos/keka.html)) | Gratis dal sito; $6.49 sul MAS (pagina US) |
| **BetterZip 6** (6.0 del 20 luglio 2026, [blog](https://macitbetter.com/blog/BetterZip-6.0/)) | Browser di archivi stile Finder (lista, outline, icone, colonne), split view | Menu contestuale Finder, pulsante toolbar, Share extension, preset da menu/Shortcuts/CLI ([macitbetter.com](https://macitbetter.com/)) | Ottimo: Quick Look extension, viewer immagini a schermo intero, anteprima HTML, importer Spotlight dei nomi file | Sì: aggiungi, elimina, rinomina, modifica con salvataggio automatico nell'archivio | AES-256, vault password cifrato con applicazione automatica, generatore di password | Progress con tempo residuo, mostrato anche sull'archivio nel Finder; log persistente per archivio | Filtri per nome/percorso/età/dimensione (.DS_Store, Thumbs.db); preset "Clean and Zip" ([Xojo forum](https://forum.xojo.com/t/do-you-ship-support-files-in-a-zip-archive/87419)) | $35 una tantum, 30 giorni di prova; Setapp; fuori dal MAS dal 2015 ([blog](https://macitbetter.com/blog/Good-Bye--Mac-App-Store)) |
| **The Unarchiver** 4.3.9 (MacPaw, [MAS](https://apps.apple.com/us/app/the-unarchiver/id425424353)) | Nessuna UI di lavoro: app di default, doppio clic e via | Doppio clic, apertura con l'app | Nessuno | No | Apre ZIP/RAR protetti; nessuna creazione | Minimale; un recensore critica l'interfaccia "vuota finché non parte l'estrazione" | Opzioni: destinazione, crea cartella (anche "solo se più elementi al primo livello"), apri cartella, sposta l'archivio nel Cestino ([Macworld](https://www.macworld.com/article/220919/mac-gems-the-unarchiver-is-a-free-robust-file-extraction-utility.html), [man unar](https://man.archlinux.org/man/unar.1)); selettore di encoding per i nomi file | Gratis; nella 4.3.9 aggiunti un sondaggio e analytics d'uso |
| **Archiver 5** (Incredible Bee; richiede macOS 26, [archiverapp.com](https://archiverapp.com/)) | Finestra unica a drop zone, design Liquid Glass | Drag & drop; menu contestuale e Quick Action ([Setapp](https://setapp.com/app-reviews/winzip-alternatives-for-mac)); il contesto è finito sotto "Services" ([recensioni Setapp](https://setapp.com/apps/archiver/customer-reviews)) | Anteprima QuickLook dentro l'archivio, estrazione selettiva | Non documentata | AES-256 | Più archivi estratti in parallelo | Livelli di compressione, cartella di output, rimozione automatica dell'archivio dopo l'estrazione (opzionale) | Archiver 4 $26 sul MAS; Archiver 5 su Setapp (5.0.11) e upgrade scontato; la versione MAS non crea RAR per via del sandbox ([ricerca](https://app2.archiverapp.com/support)) |
| **Archive Utility** (integrata in macOS) | Invisibile: Finder → Comprimi / doppio clic | Menu Finder "Comprimi"; doppio clic sullo ZIP | Nessuno (solo Quick Look di sistema) | No | Nessuna dalla UI | Piccola finestra di progresso; errori generici "Unable to expand" | "Keep expanding if possible" attivo, "Reveal expanded item" attivo, archivio lasciato dove si trova ([Intego](https://www.intego.com/mac-security-blog/understanding-compressed-files-and-apples-archive-utility/)); "Comprimi" crea sempre ZIP con `__MACOSX` | Gratis |
| **WinZip Mac 12** (Corel) | App "file manager" con schede, cloud (Dropbox/Drive/OneDrive) | Finestra app, integrazione cloud | Anteprima PDF prima dell'estrazione ([rivenditore](https://www.surfspot.nl/en/corel-winzip-mac-12-pro.html)) | Copia/sposta/rinomina/elimina | AES-256 di default | n.d. | n.d. | Licenza perpetua dai rivenditori; versione MAS con abbonamento dopo la prova; How-To Geek cita $35/anno |
| **PeaZip** 11.4.0 ([pagina macOS](https://peazip.github.io/peazip-macos.html)) | File manager e archive manager cross-platform (Lazarus) | Workflow Automator da installare a mano nei Services | Browser integrato | Sì | AES-256, verifica integrità, secure delete | n.d. | n.d. | Gratis; binari **non firmati/notarizzati**, serve `xattr -dr com.apple.quarantine` |
| **Commander One** / **ForkLift 4** | File manager a due pannelli | Archivio aperto come cartella (Invio) | Sì, come cartella | Commander One: copia/sposta tra archivi, elimina ([Eltima wiki](https://wiki.eltima.com/user-guides/commander/extract.html)) | n.d. | Coda del file manager | n.d. | Commander One gratis solo ZIP, altri formati nel PRO Pack (~$29.99); ForkLift: sfoglia, anteprima e cerca dentro gli archivi ([binarynights](https://binarynights.com/)) |
| **MacPacker** 0.15.x (open source, SwiftUI, [GitHub](https://github.com/sarensw/MacPacker)) | Browser stile Finder (breadcrumb, colonne ordinabili, ricerca) | Finder extension, Quick Look extension, drag-out | Archivi annidati navigabili anche in Quick Look; formato riconosciuto dal magic number | ZIP/7z: aggiungi, sostituisci, elimina | AES-256, volumi | n.d. | "Smart extraction": cartella col nome dell'archivio, mai doppia cartella se c'è già una sola cartella radice | Gratis (GPL-3), 21 lingue |
| **Entropy** (Eigenlogik) | Dual mode: auto-estrai oppure vista contenuti | — | Sì | Sì | Password manager integrato | — | Filtri per gli elementi da scartare | **Abbandonata**: nessun update dal dicembre 2013 ([AlternativeTo](https://alternativeto.net/software/entropy/about)) |

Altre app minori viste: **iZip** (gratis con IAP $29.99, look stile 7-Zip), **Unzip One** (gratis, drag & drop) ([How-To Geek](https://tech.yahoo.com/articles/macos-bad-unzipping-files-heres-173015069.html)), **ZipDiplomat** (app a pagamento che esiste solo per togliere `__MACOSX`/.DS_Store dagli zip, [MAS](https://apps.apple.com/us/app/zipdiplomat-clean-archives/id6759848121?mt=12)). "Zipic" e "Compresto" sono compressori di immagini e video, non archiviatori, quindi non rilevanti.

---

## 2. Punti forti e deboli UX per concorrente

### Keka
**Forti**
- Flusso "zero UI": trascini sull'icona del Dock, l'archivio viene creato nel formato di default e Keka chiede qualcosa solo se gli serve un nome o una destinazione ([Macworld](https://www.macworld.com/article/614130/keka-review.html); [keka.io](https://www.keka.io/en/): "non serve nemmeno aprire Keka").
- Una sola superficie per comprimere ed estrarre; più operazioni in parallelo con colori e stima del tempo ([How-To Geek](https://tech.yahoo.com/articles/macos-bad-unzipping-files-heres-173015069.html)).
- Esclude di default le risorse Mac, la cosa che più conta per chi spedisce zip a utenti Windows ([Uni Hamburg](https://www.ew.uni-hamburg.de/service/digitale-arbeit/anleitungen/howtos/keka.html), [pctipp](https://pctipp.ch/themen/praxis/mac-tipp-unsichtbares-unter-windows)).
- Recensori MAS: "il gestore di archivi di terze parti più stabile che abbia usato", veloce con file grandi ([MAS](https://apps.apple.com/us/app/keka/id470158793)).

**Deboli**
- La prima finestra non fa capire di essere una drop zone e il selettore di formato confonde; l'icona ha poco contrasto (recensione MAS, 2022).
- Non c'è una richiesta di password a colpo singolo: per creare uno zip cifrato bisogna passare da File → New ([Macworld](https://www.macworld.com/article/614130/keka-review.html)), oppure attivare "chiedi sempre la password".
- **Attrito con il sandbox**: Keka chiede l'accesso alle cartelle. Per la compressione bisogna aggiungere le cartelle a mano nella lista "File Access", e Full Disk Access non basta. Gli utenti segnalano richieste ripetute anche dopo aver concesso la home ([wiki Sandbox](https://github.com/aonez/Keka/wiki/Sandbox), [issue #325](https://github.com/aonez/Keka/issues/325), [issue #1408](https://github.com/aonez/keka/issues/1408)).
- Diventare app di default richiede un helper separato da scaricare (KekaExternalHelper) ([keka.io](https://www.keka.io/en/), [Setapp](https://setapp.com/app-reviews/winzip-alternatives-for-mac)).
- Non permette di guardare dentro un archivio prima di estrarlo.

### BetterZip 6
**Forti**
- È lo standard per "ispezionare prima di estrarre": viste come nel Finder, Quick Look extension, viewer per immagini e fumetti, Spotlight sui nomi dentro gli archivi ([blog 6.0](https://macitbetter.com/blog/BetterZip-6.0/)).
- Preset riusabili ovunque (Finder, Shortcuts, CLI); "Clean and Zip" è citato spontaneamente dagli utenti per creare "zip senza la spazzatura macOS" ([Xojo forum](https://forum.xojo.com/t/do-you-ship-support-files-in-a-zip-archive/87419)).
- Vault delle password con applicazione automatica; finestra di risoluzione dei conflitti riprogettata; rinomina per compatibilità Windows; estrazione piatta; salto delle cartelle vuote.
- Progress con tempo residuo visibile anche sull'icona nel Finder; log per archivio con percorsi cliccabili.
- Mantiene il flag di quarantena sugli eseguibili estratti, una scelta di sicurezza ([BetterZip 5.4](https://alternativeto.net/news/2025/9/betterzip-5-4-brings-new-file-previews-finder-style-selection-macos-26-support-and-more)).
- Setapp: 96% su circa 2.500 valutazioni; viene lodata la reattività dello sviluppatore ([Setapp](https://setapp.com/apps/betterzip/customer-reviews)).

**Deboli** (recensioni Setapp)
- "UI molto confusa e poco focalizzata": un utente propone un flusso semplice Estrai/Comprimi.
- "Troppi clic per estrarre": lo sviluppatore rimanda a un'impostazione, quindi il default non è quello che l'utente si aspetta.
- Non chiede di cifrare al salvataggio o quando si aggiungono file.
- Picchi di memoria da 40 a 80 GB con una cartella Favorites enorme; segnalazioni di file mancanti dopo l'apertura di un tar.gz (smentite dallo sviluppatore) e dopo la compressione di file grandi.
- Il prezzo è salito a $35 e l'app non è più sul MAS.

### The Unarchiver
**Forti**
- Zero frizione: "Free. Fast. Low friction.", è la risposta tipica di Reddit per gli zip e i rar che non si aprono ([ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733)).
- Ottima gestione dell'encoding dei nomi file (archivi Windows non latini) con selettore manuale ([compresto](https://compresto.app/blog/keka-vs-the-unarchiver)); unisce .001/.002 e i RAR multivolume ([theunarchiver.com](https://theunarchiver.com/)).
- Opzione "crea cartella solo se ci sono più elementi al primo livello" ([man unar](https://man.archlinux.org/man/unar.1)).
- Valutata "molto accessibile" con VoiceOver da AppleVis (test datato, macOS 10.8) ([AppleVis](https://www.applevis.com/apps/mac/utilities/unarchiver)).

**Deboli** (recensioni MAS 2017-2020)
- Le estrazioni fallite non danno dettagli utili: un utente ha dovuto usare il "test" di un'altra app per trovare la parte corrotta.
- Crash o hang aprendo più di circa 250 file dal Finder; notifiche di encoding casuali.
- Deselezionando un formato nelle preferenze compare un dialogo che obbliga a scegliere un'altra app di default.
- Preferenze aperte al primo avvio e finestra vuota finché non si estrae.
- Nella 4.3.9 sono arrivati un sondaggio e analytics d'uso: per un'app "free and always will be" la percezione sulla privacy conta.
- Non crea archivi.

### Archiver 5 (Incredible Bee)
**Forti**
- Una finestra, si trascina dentro e "pensa a tutto lei"; split, combine e checksum; estrazioni parallele; anteprima QuickLook senza estrarre; aggiornata a Liquid Glass su macOS 26 ([archiverapp.com](https://archiverapp.com/)). È il concorrente più diretto di Xipper per piattaforma e design.
- Setapp 97% su circa 1.600 valutazioni: "very simple, no-hassle" ([Setapp](https://setapp.com/apps/archiver/customer-reviews)).

**Deboli** (recensioni Setapp)
- Crash in estrazione, RAR multiparte (`01.rar`, `02.rar`) che mandano in crash l'app, zip multivolume problematici, crash su 7z.
- Errori intermittenti con le password, "could not create archive" ripetuto, freeze zippando 186 file.
- **Richieste ripetute di diventare l'app di default**: un utente chiede un pulsante per decidere una volta sola (lo sviluppatore dice di averlo corretto).
- "Lento e macchinoso": un utente non capiva come vedere l'anteprima, che compare solo trascinando dentro l'archivio, quindi non è scopribile.
- Il menu contestuale è sotto "Services" invece che al primo livello.
- La versione MAS ha meno funzioni di quella diretta (niente creazione RAR).

### Archive Utility (macOS)
**Forti**: zero configurazione, integrata nel Finder, istantanea per gli ZIP.

**Deboli**
- Solo ZIP, GZIP, TAR, CPIO, XAR: fallisce su RAR e 7z, spesso con un generico "Unable to expand". Gli utenti vedono zip che "falliscono e poi si aprono senza problemi altrove" ([ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733), [iBoysoft](https://iboysoft.com/howto/fix-unable-to-expand-zip-mac.html)).
- Errori opachi: "Error 1 – Operation not permitted", "Error 79". Le cause possibili (archivio danneggiato, rinominato, oltre 4 GB, disco pieno) non vengono distinte ([MathWorks](https://mathworks.com/matlabcentral/answers/460598-why-do-i-get-a-decompression-failed-or-unable-to-expand-error-when-downloading-r2018b-update-4-o)).
- **Fallimenti silenziosi**: estraendo più zip insieme mancavano file (48 su 50, 22 su 50) senza alcun avviso ([Apple Community](https://discussions.apple.com/thread/254277676)).
- Cartella "wrapper" doppia quando lo zip contiene già una cartella con lo stesso nome ([guida](https://cloud.motorsport.unibo.it/article/the-essential-mac-guide-how-to-extract-a-zip-file-in-mac-2024), fonte debole).
- "Comprimi" crea zip con `__MACOSX` e `._*` che gli utenti Windows vedono come spazzatura; non c'è un'opzione per escluderli ([iBoysoft](https://iboysoft.com/wiki/what-is-macosx-folder.html), [Xojo forum](https://forum.xojo.com/t/do-you-ship-support-files-in-a-zip-archive/87419)).
- Sicurezza: CVE-2022-32910 (bypass di Gatekeeper, [Jamf](https://www.jamf.com/blog/jamf-threat-labs-macos-archive-utility-vulnerability/)) e una falla TCC corretta in macOS 26.4 ([MacG, maggio 2026](https://www.macg.co/macos/2026/05/loutil-de-decompression-de-macos-servait-de-vecteur-dans-une-faille-corrigee-avec-macos-264-308737)).

### WinZip for Mac
**Forti**: nome familiare per chi arriva da Windows, integrazione cloud, AES-256 di default, anteprima PDF.
**Deboli**: prezzo e abbonamento difficili da giustificare per l'uso locale ([compresto](https://compresto.app/blog/best-archive-tools-for-mac), [ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733)); "non sembra nativa per Mac" ([Setapp](https://setapp.com/app-reviews/winzip-alternatives-for-mac)); sulle app mobile sorelle si lamentano prompt di abbonamento aggressivi (aggregatore, evidenza debole).

### PeaZip
**Forti**: oltre 200 formati, verifica e riparazione, gratuita, build nativa Apple Silicon.
**Deboli**: UI non nativa ("più Linux che macOS", [compresto](https://compresto.app/blog/best-archive-tools-for-mac)); binari non firmati, con avviso "sviluppatore non verificato" e istruzioni `xattr` nel Terminale; integrazione nel Finder tramite workflow Automator installati a mano ([peazip.github.io](https://peazip.github.io/peazip-macos.html)).

### Commander One / ForkLift
**Forti**: aprire l'archivio come una cartella qualsiasi è il modello mentale più naturale per chi usa già un file manager.
**Deboli**: Commander One mette i formati diversi da ZIP dietro il paywall PRO, e gli utenti se ne lamentano ("pricing split", [ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733)).

### MacPacker (nuovo, da tenere d'occhio)
**Forti**: SwiftUI nativo, "archivi come cartelle", archivi annidati anche in Quick Look, drag-out selettivo, smart extraction che evita la doppia cartella, formato riconosciuto dal magic number, 21 lingue ([GitHub](https://github.com/sarensw/MacPacker)).
**Deboli**: ancora 0.x; integrità e recovery sono "coming next".

---

## 3. Feedback ricorrenti degli utenti macOS

### Lodi
| Tema | Esempi concreti | Fonte |
|---|---|---|
| **"Funziona e basta", nessuna UI** | The Unarchiver "Free. Fast. Low friction."; Archiver "very simple, no-hassle" | [ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733), [Setapp Archiver](https://setapp.com/apps/archiver/customer-reviews) |
| **Drop sul Dock / sulla finestra** | Keka: comprimere senza aprire l'app; prompt solo se serve | [keka.io](https://www.keka.io/en/), [Macworld](https://www.macworld.com/article/614130/keka-review.html) |
| **Vedere prima di estrarre** | BetterZip: browse e modifica senza estrarre tutto, "confiable, potente y muy intuitivo" | [Setapp BetterZip](https://setapp.com/apps/betterzip/customer-reviews) |
| **Zip puliti per Windows** | Keka e BetterZip "Clean and Zip" consigliati per evitare "the macOS hidden junk" | [Xojo forum](https://forum.xojo.com/t/do-you-ship-support-files-in-a-zip-archive/87419) |
| **Stabilità** | Keka "the most stable third party archive manager" | [MAS Keka](https://apps.apple.com/us/app/keka/id470158793) |
| **Velocità** | BetterZip "light and fast on an M4"; Keka veloce con file grandi | [Setapp](https://setapp.com/apps/betterzip/customer-reviews), [MAS](https://apps.apple.com/us/app/keka/id470158793) |
| **Supporto reattivo dello sviluppatore** | BetterZip "extremely responsive and detailed"; Keka supporto rapido | [Setapp](https://setapp.com/apps/betterzip/customer-reviews), [MAS](https://apps.apple.com/us/app/keka/id470158793) |
| **Encoding dei nomi file** | The Unarchiver gestisce archivi Windows non latini | [compresto](https://compresto.app/blog/keka-vs-the-unarchiver) |
| **Niente abbonamento** | Keka ed Entropy citati come alternative senza abbonamento a WinZip | [compresto](https://compresto.app/blog/best-archive-tools-for-mac) |

### Lamentele
| Tema | Esempi concreti | Fonte |
|---|---|---|
| **Errori opachi o assenti** | Archive Utility "Unable to expand" ed "Error 1" senza causa; The Unarchiver non dice quale parte è corrotta; Archive Utility perde file in silenzio nel batch | [MAS Unarchiver](https://apps.apple.com/us/app/the-unarchiver/id425424353), [Apple Community](https://discussions.apple.com/thread/254277676), [iBoysoft](https://iboysoft.com/howto/fix-unable-to-expand-zip-mac.html) |
| **Multi-parte e RAR fragili** | Archiver: `01.rar`/`02.rar` mandano in crash l'app, zip multivolume problematici | [Setapp Archiver](https://setapp.com/apps/archiver/customer-reviews) |
| **Password** | Archiver: errori intermittenti con le password; BetterZip non propone la cifratura al salvataggio; Keka non chiede la password in compressione | [Setapp Archiver](https://setapp.com/apps/archiver/customer-reviews), [Setapp BetterZip](https://setapp.com/apps/betterzip/customer-reviews), [Macworld](https://www.macworld.com/article/614130/keka-review.html) |
| **Permessi e sandbox** | Keka chiede accesso alle cartelle in modo ripetuto, Full Disk Access non aiuta; PeaZip chiede accesso alle cartelle al primo uso | [Keka #325](https://github.com/aonez/Keka/issues/325), [#1408](https://github.com/aonez/keka/issues/1408), [PeaZip](https://peazip.github.io/peazip-macos.html) |
| **Nag "app di default"** | Archiver chiede ripetutamente di diventare app di default; The Unarchiver forza il cambio di default quando deselezioni un formato; Keka richiede un helper separato | [Setapp Archiver](https://setapp.com/apps/archiver/customer-reviews), [MAS Unarchiver](https://apps.apple.com/us/app/the-unarchiver/id425424353), [keka.io](https://www.keka.io/en/) |
| **Junk macOS negli zip** | `__MACOSX`, `._*`, .DS_Store visibili su Windows; esiste persino un'app a pagamento solo per toglierli (ZipDiplomat) | [iBoysoft](https://iboysoft.com/wiki/what-is-macosx-folder.html), [Xojo](https://forum.xojo.com/t/do-you-ship-support-files-in-a-zip-archive/87419), [MAS ZipDiplomat](https://apps.apple.com/us/app/zipdiplomat-clean-archives/id6759848121?mt=12) |
| **Doppia cartella in estrazione** | Wrapper ridondante quando lo zip ha già una cartella con lo stesso nome | [guida](https://cloud.motorsport.unibo.it/article/the-essential-mac-guide-how-to-extract-a-zip-file-in-mac-2024) (fonte debole) |
| **UI poco scopribile o confusa** | Keka: la finestra non sembra una drop zone; BetterZip "confusing and unfocused", "too many clicks"; Archiver: anteprima introvabile | [MAS Keka](https://apps.apple.com/us/app/keka/id470158793), [Setapp BetterZip](https://setapp.com/apps/betterzip/customer-reviews), [Setapp Archiver](https://setapp.com/apps/archiver/customer-reviews) |
| **Menu contestuale nascosto** | Archiver sotto "Services" invece che al primo livello | [Setapp Archiver](https://setapp.com/apps/archiver/customer-reviews) |
| **Scalabilità** | The Unarchiver va in crash con più di 250 file; BetterZip arriva a 40-80 GB di RAM; Archiver si blocca con 186 file | [MAS Unarchiver](https://apps.apple.com/us/app/the-unarchiver/id425424353), [Setapp](https://setapp.com/apps/betterzip/customer-reviews) |
| **Prezzo e paywall** | WinZip ad abbonamento; formati di Commander One dietro PRO; MAS e versione diretta con funzioni diverse (Archiver, Keka) | [ping.fm](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733), [Setapp](https://setapp.com/app-reviews/winzip-alternatives-for-mac) |
| **Icona e estetica** | Keka icona a basso contrasto; BetterZip icona "looks terrible" | [MAS Keka](https://apps.apple.com/us/app/keka/id470158793), [Setapp BetterZip](https://setapp.com/apps/betterzip/customer-reviews) |

Non trovate o non verificate: lamentele specifiche su "password prompt che perde il focus" e su "nessun progress per file grandi" (il tema c'è solo indirettamente: The Unarchiver ha una UI vuota, BetterZip 6 ha introdotto apposta il tempo residuo). Non ho trovato recensioni sull'accessibilità recenti per nessuna app, se non AppleVis su The Unarchiver.

---

## 4. Pattern UX

### Da copiare
1. **Drop sull'icona del Dock e sulla finestra, con prompt solo se serve** (Keka).
2. **Smart extraction**: una cartella col nome dell'archivio solo se al primo livello c'è più di un elemento, mai una doppia cartella (The Unarchiver/`unar`, MacPacker).
3. **Archivi come cartelle**: browse stile Finder con anteprima Quick Look, drag-out selettivo e archivi annidati (BetterZip 6, MacPacker, ForkLift).
4. **Zip puliti di default**: esclusione di .DS_Store, `__MACOSX`, `._*`, con preset tipo "Clean and Zip" e rinomina per compatibilità Windows (Keka, BetterZip).
5. **Vault password nel Keychain con applicazione automatica** e generatore (BetterZip). Xipper ha già le chiavi nel Keychain: va esteso alle password degli archivi.
6. **Progress con tempo residuo, anche nel Finder e sull'icona del Dock**, più un log per archivio (BetterZip 6).
7. **Preset riusabili** da Finder, Shortcuts/App Intents e CLI (BetterZip 6).
8. **Finestra di risoluzione conflitti** chiara (Sostituisci / Mantieni entrambi / Salta, "applica a tutti") (BetterZip 6).
9. **Quarantena preservata** sugli eseguibili estratti (BetterZip 5.4).
10. **Riconoscimento del formato dal magic number** e non dall'estensione (MacPacker): risolve il caso del ".zip che in realtà è un 7z/RAR" ([iBoysoft](https://iboysoft.com/howto/fix-unable-to-expand-zip-mac.html)).
11. **Selettore di encoding** per nomi file non UTF-8 (The Unarchiver).

### Da evitare
1. **Messaggi d'errore generici** ("Unable to expand", "Error 1") e **fallimenti silenziosi** (Archive Utility).
2. **Nag per diventare app di default** ripetuto, oppure imposto (Archiver, The Unarchiver).
3. **Permessi a raffica e liste "File Access" da gestire a mano** (Keka). Nella stessa direzione: Full Disk Access che non serve.
4. **Funzioni scopribili solo per caso** (anteprima di Archiver, drop zone di Keka).
5. **Menu contestuale sepolto in "Services"**.
6. **UI dense da power user come unica modalità** (BetterZip "confusing and unfocused").
7. **Cifratura raggiungibile solo da un percorso secondario** (Keka File → New).
8. **Differenze di funzioni tra versione MAS e diretta** che l'utente scopre dopo.
9. **Telemetria e sondaggi in un'app che si presenta come semplice** (The Unarchiver 4.3.9).
10. **Binari non firmati e istruzioni da Terminale** (PeaZip). Per Xipper vale come promemoria: una DMG self-signed produce lo stesso avviso di Gatekeeper, quindi serve almeno una guida d'installazione chiara.

---

## 5. Idee concrete per Xipper (in ordine di priorità)

1. **Errori parlanti e azionabili.** Un enum di errori mappato su testi umani con causa ed eventuale azione: "Password errata" (con il campo che resta a fuoco e scuote), "Archivio danneggiato: la parte 3 di 5 è incompleta (attesi 100 MB, trovati 62 MB)", "Manca la parte `.z02`" con un pulsante "Individua…", "Il file si chiama .zip ma è un archivio 7z: apro lo stesso?", "Spazio insufficiente: servono 4,2 GB, liberi 1,1 GB" (controllato *prima* di iniziare). Alla fine mostra sempre un riepilogo ("1.248 file estratti, 2 saltati: dettagli"), mai fallimenti silenziosi.
2. **Smart extraction di default.** Estrai accanto all'archivio. Se al primo livello c'è un solo elemento, nessuna cartella aggiuntiva; altrimenti una cartella col nome dell'archivio. Nomi in collisione risolti con "Nome 2" e non sovrascritti. Mostra il risultato nel Finder (attivo di default, disattivabile).
3. **Zip "puliti per tutti" di default.** Esclusione di .DS_Store, `__MACOSX`, `._*`, Icon\r, e opzionalmente Thumbs.db, con un toggle visibile nel pannello di compressione ("Compatibile con Windows"). Aggiungi la rinomina dei caratteri illegali su Windows (`: * ? " < > |`) e un avviso sui percorsi lunghi.
4. **Azioni rapide ovunque, al primo livello.** Finder Sync o Action extension con "Comprimi", "Comprimi con password…", "Estrai qui", "Estrai in…", "Apri in Xipper". Aggiungi Quick Actions per Services e Shortcuts/App Intents ("Comprimi con preset X"), drop sull'icona del Dock e una Share extension. Mai solo sotto "Services".
5. **Quick Look extension per gli archivi**, inclusi XIZ: lista dei file con dimensioni e un'anteprima del primo livello senza aprire l'app. Per XIZ cifrato mostra i metadati in chiaro e "Contenuto cifrato: apri con Xipper".
6. **Finestra principale a due modalità.** Vuota, è una drop zone *esplicita* in Liquid Glass ("Trascina file per comprimerli o un archivio per aprirlo") con due pulsanti grandi, Comprimi e Apri, per chi non trascina. Con un archivio aperto diventa un browser stile Finder (lista e colonne, breadcrumb, ricerca, Quick Look con la barra spaziatrice, drag-out selettivo). Resta così semplice per l'utente occasionale e profonda per il power user.
7. **Password UX di prima classe.** Campo password direttamente nel pannello di compressione (non un percorso secondario), con indicatore di robustezza, generatore e "Salva nel Portachiavi". In apertura prova in automatico le password salvate (come il vault di BetterZip) e mostra il prompt come sheet che prende il focus, con "Mostra password" e il numero di tentativi. Dì chiaramente se i *nomi* dei file sono cifrati oppure no (ZIP non li nasconde, 7z e XIZ sì).
8. **Progress percepito e reale.** Progress determinato con byte e file, velocità e tempo residuo; badge e barra sull'icona del Dock (`NSDockTile`); notifica al termine se l'app non è in primo piano. Pausa e annulla con pulizia dei file parziali. Una coda visibile con più job paralleli, distinti per colore e icona come in Keka. Scrivi `NSProgress` sul file perché il Finder mostri l'avanzamento.
9. **Permessi senza attrito.** Se Xipper è sandboxed, chiedi l'accesso *una volta* con un `NSOpenPanel` preimpostato sulla cartella giusta e un testo che spieghi il perché, quindi salva un security-scoped bookmark. Mai liste "File Access" da gestire a mano. Se non è sandboxed (distribuzione DMG), dichiaralo nell'onboarding come vantaggio.
10. **Default app senza nag.** Una sola schermata di onboarding con le caselle "Apri questi formati con Xipper" (ZIP, 7z, RAR, XIZ…) e "Non chiedere più". La scelta si cambia in Impostazioni e non ricompare mai a sorpresa.
11. **Multi-volume e RAR robusti.** Riconosci automaticamente `.001`, `.z01`, `.part1.rar` e `.7z.001` anche aprendo una parte qualsiasi. Mostra quali parti sono presenti o mancanti prima di iniziare. Offri un test di integrità (CRC) come azione esplicita con un report per file. Le recensioni Setapp di Archiver dimostrano che è il punto più fragile della categoria.
12. **Sicurezza visibile ma non invadente.** Preserva la quarantena sugli eseguibili estratti. Blocca zip-slip e path traversal (va coerente con il lavoro già fatto in `ExtractionContext.swift` e nei test di security hardening) e mostra un avviso leggibile ("Questo archivio conteneva 1 file con percorso non sicuro, saltato"). Avvisa sulle zip bomb con il rapporto di espansione stimato.
13. **Preset ed esperienza Shortcuts.** 3-4 preset di serie (Condivisione rapida ZIP compatibile Windows, Massima compressione 7z, Archivio sicuro XIZ, Backup) modificabili, esposti come App Intents e nel menu del Finder. Riduce la complessità delle impostazioni senza togliere potenza.
14. **Accessibilità come differenziatore.** Nessun concorrente ne parla. Servono label VoiceOver per righe e azioni (incluse dimensioni e stato di cifratura), alternative da tastiera al drag & drop (Comando-O, Comando-Shift-C, Comando-E), annunci (`AccessibilityNotification.Announcement`) a inizio e fine operazione e sugli errori, rispetto di Riduci trasparenza e Aumenta contrasto (critico con Liquid Glass) e di Riduci movimento, Dynamic Type dove possibile. Fai un test con VoiceOver prima di ogni release.
15. **Localizzazione e fiducia.** String Catalog con almeno IT, EN, DE, FR, ES, JA e ZH (Keka e MacPacker coprono 20 lingue o più). Una dichiarazione "nessuna telemetria" chiara. Una guida d'installazione per la DMG self-signed (Gatekeeper) con screenshot, per non ripetere l'esperienza PeaZip.

---

### Fonti principali
- Keka: [keka.io](https://www.keka.io/en/), [Mac App Store](https://apps.apple.com/us/app/keka/id470158793), [Macworld](https://www.macworld.com/article/614130/keka-review.html), [wiki Sandbox](https://github.com/aonez/Keka/wiki/Sandbox), [issue #325](https://github.com/aonez/Keka/issues/325), [issue #1408](https://github.com/aonez/keka/issues/1408)
- BetterZip: [macitbetter.com](https://macitbetter.com/), [BetterZip 6.0](https://macitbetter.com/blog/BetterZip-6.0/), [5.4 su AlternativeTo](https://alternativeto.net/news/2025/9/betterzip-5-4-brings-new-file-previews-finder-style-selection-macos-26-support-and-more), [recensioni Setapp](https://setapp.com/apps/betterzip/customer-reviews)
- The Unarchiver: [theunarchiver.com](https://theunarchiver.com/), [Mac App Store](https://apps.apple.com/us/app/the-unarchiver/id425424353), [Macworld](https://www.macworld.com/article/220919/mac-gems-the-unarchiver-is-a-free-robust-file-extraction-utility.html), [AppleVis](https://www.applevis.com/apps/mac/utilities/unarchiver)
- Archiver: [archiverapp.com](https://archiverapp.com/), [recensioni Setapp](https://setapp.com/apps/archiver/customer-reviews)
- Archive Utility: [Intego](https://www.intego.com/mac-security-blog/understanding-compressed-files-and-apples-archive-utility/), [Apple Community](https://discussions.apple.com/thread/254277676), [Jamf CVE-2022-32910](https://www.jamf.com/blog/jamf-threat-labs-macos-archive-utility-vulnerability/), [MacG 2026](https://www.macg.co/macos/2026/05/loutil-de-decompression-de-macos-servait-de-vecteur-dans-une-faille-corrigee-avec-macos-264-308737)
- Altri: [PeaZip macOS](https://peazip.github.io/peazip-macos.html), [MacPacker](https://github.com/sarensw/MacPacker), [Eltima Commander One](https://wiki.eltima.com/user-guides/commander/extract.html), [BinaryNights ForkLift](https://binarynights.com/), [How-To Geek via Yahoo](https://tech.yahoo.com/articles/macos-bad-unzipping-files-heres-173015069.html), [Setapp alternatives](https://setapp.com/app-reviews/winzip-alternatives-for-mac), [compresto (vendor)](https://compresto.app/blog/best-archive-tools-for-mac), [ping.fm (riassunto Reddit)](https://community.ping.fm/t/what-s-the-best-unarchiver-for-mac-that-reddit-users-recommend/2733), [Xojo forum](https://forum.xojo.com/t/do-you-ship-support-files-in-a-zip-archive/87419)

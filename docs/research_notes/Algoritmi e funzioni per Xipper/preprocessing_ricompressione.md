# Preprocessing specifico per contenuto e ricompressione lossless per Xipper

Note di ricerca (novembre 2026). Il report precedente («Nuovo formato di compressione Xipper») copre già dedup per file e FastCDC, ordinamento per similarità, dizionari zstd, la cifra di circa il 5% del filtro ARM64 sul kernel e la selezione automatica dei filtri di 7-Zip 23. Qui si aggiunge solo il materiale nuovo o più dettagliato. Ogni affermazione ha una fonte. Le inferenze sono separate dai fatti.

## 1. Ricompressione lossless dei JPEG: Lepton, packJPG, JPEG XL, brunsli

### Takeaway
Tutte e quattro le tecniche danno circa il 20-23% su JPEG reali, con ricostruzione bit-exact. Per Xipper l'opzione migliore è **JPEG XL in modalità transcoding (libjxl, BSD-3)**, perché è uno standard ISO, è mantenuta e il decoder è già in macOS. La seconda scelta è **lepton_jpeg_rust di Microsoft (Apache-2.0)**, che si integra come blob opaco ma non ha release taggate. Il Lepton originale di Dropbox è archiviato. packJPG ha una licenza problematica per MIT (vedi Gaps).

### Cited Findings
- **Lepton (paper)**: comprime i JPEG in modo lossless «al 77% della dimensione originale in media» (circa -23%). Eguaglia la migliore tecnica precedente e decodifica «più di nove volte più veloce», in streaming. A febbraio 2017 aveva compresso più di 203 PiB di JPEG utente in Dropbox, risparmiando più di 46 PiB. — [Horn et al., NSDI'17 / arXiv:1704.06192](https://arxiv.org/abs/1704.06192); [USENIX NSDI'17](https://usenix.org/conference/nsdi17/technical-sessions/presentation/horn)
- Lepton aveva come obiettivo di progetto una decodifica abbastanza veloce da saturare una connessione tipica (>100 Mbit/s), con decodifica parallela a 8 vie. — [arXiv:1704.06192](https://arxiv.org/pdf/1704.06192); [slide NSDI'17](https://www.usenix.net/sites/default/files/conference/protected-files/nsdi17_slides_horn.pdf)
- Lo stesso paper confronta Lepton con packJPG: stessa efficienza, decodifica più di 9 volte più veloce. — [arXiv:1704.06192](https://arxiv.org/pdf/1704.06192)
- **Dropbox Lepton (C++)**: archiviato il 14 febbraio 2023, in sola lettura. Licenza Apache-2.0. Il README dichiara una media del 22% e rimanda all'implementazione Rust di Microsoft, oppure a WebP/JPEG XL. In caso di fallimento produce 0 byte e un exit code non zero. — [github.com/dropbox/lepton](https://github.com/dropbox/lepton)
- **lepton_jpeg_rust (Microsoft)**: licenza Apache-2.0. È un port in Rust di Lepton, fatto dopo una security review del codice C++. Gestisce JPEG baseline e progressivi «fino al 22%», con «recupero preciso bit per bit» e verifica end-to-end. Ha prestazioni dichiarate «sostanzialmente uguali» al C++, con AVX2 opzionale. Al momento della consultazione la sezione Releases è vuota: niente versioni taggate. Richiede Rust 1.89+. Il README non parla di ARM64 né di macOS. — [github.com/microsoft/lepton_jpeg_rust](https://github.com/microsoft/lepton_jpeg_rust)
- **brunsli (Google)**: riduzione del 22%, con JPEG originale «recuperabile byte per byte». Il README non dichiara lo stato di manutenzione (17 issue aperte). — [github.com/google/brunsli](https://github.com/google/brunsli)
- **JPEG XL lossless transcoding**: il man page ufficiale di cjxl dice che, per i JPEG in ingresso, il JPEG originale si può ricostruire bit per bit. I metadati di ricostruzione sono salvati di default (`-j/--lossless_jpeg`). djxl ricostruisce il JPEG originale di default. — [cjxl(1), Arch man](https://man.archlinux.org/man/cjxl.1.en); [djxl(1), Debian](https://dyn.manpages.debian.org/trixie/libjxl-tools/djxl.1)
- Il guadagno del transcoding JXL è riportato come circa il 20% ([guida](https://cococonvert.com/blog/what-is-jxl-jpeg-xl)) e circa il 22% ([mina86.com, 2025](https://mina86.com/2025/use-jpeg-xl-already/)). Sono fonti secondarie: non ho trovato una misura primaria nei documenti libjxl che ho consultato.
- **precomp** usa packJPG v2.5k per i JPEG, oltre a brunsli e brotli per i metadati JPEG, e packMP3 v1.0g per gli MP3. — [precomp-cpp README](https://github.com/schnaader/precomp-cpp)
- PowerArchiver stima solo il 15-20% sui PDF pieni di JPEG grandi, cioè il limite dei metodi JPEG-lossless (stima del vendor). — [PowerArchiver blog](https://www.powerarchiver.com/it/?p=8002)

### Inferences
- Il tetto pratico è circa il 22-23% su JPEG. Nessuna tecnica supera le altre in modo netto sul rapporto: la scelta si fa su licenza, manutenzione, velocità e rischio.
- JPEG XL è l'unico formato standardizzato (ISO/IEC 18181) e con più implementazioni. Un `.jxl` ricostruibile resta utile anche fuori da Xipper, perché macOS 14+ lo decodifica nativamente (fatto noto, non verificato in questa sessione). Il brunsli-like transcoding di JPEG XL deriva concettualmente da brunsli. Che brunsli sia stato fuso in JPEG XL è conoscenza comune, non verificata qui.
- Per un archiviatore il JPEG ricompresso dev'essere un **blob opaco**: si salva il flusso ricompresso più un flag codec e si fa sempre una **verifica round-trip in fase di compressione**. Se la ricostruzione non è identica byte per byte, si salva l'originale con zstd o store. Anche Lepton lo fa: 0 byte e fallimento esplicito.
- Questo è il **singolo guadagno più grande per le librerie foto degli utenti Mac, ma solo per i JPEG**. Gli HEIC/HEVC di iPhone non hanno un ricompressore lossless maturo (vedi Gaps).

### Gaps
- Licenza di packJPG: non verificata in questa sessione. Credo sia LGPL-3, il che renderebbe difficile includerlo staticamente in un'app MIT. Da controllare su github.com/packjpg.
- Licenza di brunsli: il README rimanda a un file LICENSE senza nominarla. Credo sia MIT, ma non l'ho verificato.
- Licenza di libjxl: BSD-3-Clause secondo la mia conoscenza ([github.com/libjxl/libjxl](https://github.com/libjxl/libjxl)), non verificata in questa sessione.
- Non ho trovato velocità misurate su Apple Silicon per lepton_jpeg_rust o per il transcoding JXL.
- HEIC/HEIF: non ho trovato nessun ricompressore lossless di HEVC con ricostruzione bit-exact che sia maturo.

## 2. Ricompressione di PNG/GIF/PDF/ZIP/DOCX: ri-codifica dei flussi Deflate interni (precomp, preflate, reflate, xtool)

### Takeaway
Ri-espandere i flussi Deflate dentro PDF, Office, ZIP e PNG e ricomprimerli con LZMA/zstd dà i guadagni più grandi su Office e PDF. L'unica cifra riproducibile è precomp su un ZIP di Silesia: **47,1 MB contro 67,4 MB di 7-Zip Ultra**, quindi -30%. Le stime dei vendor arrivano al 30-50% sui PDF e al 70% sui DOCX. **preflate-rs (Microsoft, Apache-2.0)** è il componente più adatto a Xipper: libreria, ricostruzione bit-exact, rilevamento di zlib, zlib-ng, libdeflate e miniz.

### Cited Findings
- **precomp**: licenza Apache-2.0. Gestisce flussi Deflate/zlib (PDF, PNG, ZIP), bZip2, GIF, JPG (packJPG) e MP3 (packMP3), e usa **preflate v0.3.5** (Dirk Steinke) per la ricostruzione di Deflate. Esempio misurato: un file di 67.633.896 byte (corpus Silesia in un contenitore Deflate) scende a 67.405.052 byte con 7-Zip LZMA2 Ultra e a **47.122.779 byte con Precomp**. Il ripristino è identico all'originale. Copyright fino al 2021, quindi lo sviluppo è lento. — [precomp-cpp](https://github.com/schnaader/precomp-cpp)
- **preflate-rs**: licenza Apache-2.0, di Microsoft. Estrae il testo in chiaro più un piccolo insieme di parametri di ricostruzione, poi rigenera il flusso Deflate bit-exact. Il testo in chiaro si può ricomprimere con Zstd, Brotli o LZMA. Overhead delle correzioni: **circa 0,01% per zlib a quasi tutti i livelli**, da 0,01% a 2,70% per miniz_oxide. Riconosce zlib (tutti i livelli), zlib-ng (tranne il livello 9), libdeflate (variante con hash table a 4 byte), miniz/miniz_oxide e lo zlib di Windows (codec PNG, ZIP della shell). I compressori sconosciuti fanno comunque round-trip, con un overhead più alto. Il crate `container` cerca flussi Deflate in ZIP, PNG e JPEG; il progetto cita anche docx e pdf. Niente release taggate. — [github.com/microsoft/preflate-rs](https://github.com/microsoft/preflate-rs)
- Il README di preflate-rs non pubblica guadagni finali su DOCX/PDF né velocità. — [preflate-rs](https://github.com/microsoft/preflate-rs)
- **Reflate (PowerArchiver, proprietario)**: stime del vendor, non misure. PDF medio -30-50%, fino all'85% per PDF quasi solo testo. DOCX «fino al 70%» in media. PDF con molti JPEG solo -15-20%. — [PowerArchiver blog](https://www.powerarchiver.com/it/?p=8002)
- **File iWork (.pages, .key, .numbers)**: sono ZIP che contengono file `.iwa`, a blocchi compressi con **Snappy** (header di 4 byte: uno zero più la lunghezza a 3 byte LE). Dentro ci sono messaggi protobuf. Le app iWork non si aspettano un livello di compressione preciso. Il formato è reverse-engineered da SheetJS, non documentato da Apple. — [SheetJS notes, iWork IWA](https://oss.sheetjs.com/notes/iwa/)

### Inferences
- **Office (DOCX/XLSX/PPTX) ed EPUB**: lo ZIP esterno è Deflate quasi sempre prodotto da zlib o da librerie compatibili, il caso migliore per preflate (overhead circa 0,01%). Ci si possono aspettare guadagni importanti, nell'ordine delle stime di Reflate, ma servono misure proprie: non ho trovato benchmark indipendenti.
- **iWork**: Snappy è un LZ senza entropia, quindi ricomprimere il testo in chiaro con zstd/LZMA dovrebbe dare molto. Ma serve un **ricostruttore Snappy bit-exact**, che non ho trovato: andrebbe scritto. L'encoder Snappy è deterministico per versione di libreria, quindi è fattibile se Apple usa la libreria Snappy standard. È un'ipotesi da verificare. Le immagini dentro i documenti iWork (JPEG/PNG) beneficerebbero comunque dei passi 1 e 4.
- **PDF**: i flussi FlateDecode sono spesso prodotti da zlib (Quartz/PDFKit, Ghostscript, ecc.), quindi la ricostruzione è economica. I JPEG embedded (DCTDecode) si possono passare a Lepton/JXL.
- **PNG**: preflate-rs più zstd/LZMA sul raster espanso dà un guadagno. Il guadagno è maggiore se poi si applica un codec di immagine lossless (sezione 4), ma la ricostruzione del PNG resta compito di preflate.
- **Rischio**: la ricostruzione Deflate richiede verifica in compressione, ha un costo di CPU (decompressione, analisi e ri-deflate per verificare) e una superficie di attacco da parser. Va eseguita in un processo o in una sandbox separata, con limiti di dimensione (zip bomb annidate).
- xtool e antix (encode.su) non hanno documentazione primaria affidabile che io abbia trovato: andrebbero valutati solo come riferimento, non come dipendenza.

### Gaps
- Non ho trovato benchmark indipendenti e recenti di precomp/preflate su corpus DOCX/PDF/PPTX. Sono necessari test interni.
- Non ho trovato fonti primarie per xtool/antix: licenza, manutenzione, risultati.
- Non so se Pages/Keynote usino la libreria Snappy di Google (che renderebbe la ricostruzione esatta fattibile) o un encoder interno.

## 3. Filtri per eseguibili: BCJ2, ARM64, RISC-V, binari Mach-O universali e .app

### Takeaway
ARM64 BCJ (xz 5.4.0+, 7-Zip 23.00+) dà **circa il 5%** sui binari ARM64. RISC-V (xz 5.6.0+, 7-Zip 24.03+) dà il 7-8%. BCJ2 serve solo per x86. È già tutto in liblzma, vendorizzata in Xipper e con licenza 0BSD/public domain. Il guadagno complessivo su un `.app` è più piccolo, perché asset, nib e immagini dominano il contenuto.

### Cited Findings
- **ARM64 BCJ** richiede xz ≥ 5.4.0. **RISC-V** richiede xz ≥ 5.6.0. La patch del kernel che li adotta riporta circa il -5% su ARM64 e il -7-8% su RISC-V rispetto a XZ/LZMA non filtrato. Squashfs può usare entrambi i filtri. — [LKML, patch xz 00/16 (Lasse Collin, 2024)](https://lkml.iu.edu/hypermail/linux/kernel/2407.2/04872.html); [LKML, patch 14/16](https://lkml.rescloud.iu.edu/2407.2/04866.html)
- xz 5.7.1alpha/5.8.0 (2025) aggiunge API a basso livello per i filtri BCJ RISC-V, ARM64 e x86 in `lzma/bcj.h`, «principalmente per erofs-utils», più piccoli ritocchi ai filtri BCJ. — [xz NEWS](https://github.com/tukaani-project/xz/blob/master/NEWS)
- **7-Zip 23.00 (2023-05-07)**: introduce il filtro ARM64 per 7z e xz. Analizza gli eseguibili (exe/dll) per scegliere BCJ/BCJ2 per x86 e ARM64 per ARM64. La sezione di default di BCJ2 passa da 64 a 240 MiB. **24.03 (2024-03-23)**: aggiunge il filtro RISCV. **9.32 (2013)**: BCJ2 migliorato per eseguibili oltre 16 MB. **15.05**: parametro «section size» per BCJ2. Il changelog non dà percentuali. — [7-Zip history.txt](https://www.7-zip.org/history.txt)

### Inferences
- **Universal Mach-O**: bisogna separare le slice (header `fat`) e applicare ARM64 BCJ alla slice arm64 e x86 BCJ/BCJ2 alla slice x86_64. Applicare un filtro a tutto il file degrada l'altra slice. Il report precedente lo prevede già.
- **Dove conta**: Xcode DerivedData, app in `/Applications`, framework e dylib, toolchain. Su un intero `.app` tipico, gli eseguibili sono una frazione dei byte, quindi il guadagno totale probabilmente resta di qualche punto. È un'inferenza, non misurata.
- Su Apple Silicon il costo è trascurabile (un passaggio lineare). Va abilitato sempre per le sezioni `__TEXT` riconosciute.
- Il **delta** di 7-Zip/xz è utile per dati binari tabellari e PCM grezzo (`-mf=delta:4 a.wav`, [7-Zip history](https://www.7-zip.org/history.txt)), ma è molto inferiore a un codec audio dedicato (sezione 4).

### Gaps
- Non ho trovato misure pubbliche del filtro ARM64 su binari macOS (Mach-O) o su bundle `.app`: la cifra del 5% viene dal kernel Linux. Da misurare internamente, per esempio con `xz --arm64 --lzma2` sulle slice di `/Applications/*.app`.
- Il guadagno di BCJ2 rispetto a BCJ sugli x86 moderni: nessuna cifra trovata.

## 4. Audio e immagini lossless dentro l'archivio: FLAC/WavPack/OptimFROG/TTA e JPEG XL/WebP/QOI

### Takeaway
Per WAV/AIFF non compressi, un codec audio lossless porta il file intorno al **52-61% dell'originale**. I codec migliori distano dal FLAC solo 1,5-4 punti. FLAC (BSD) o WavPack (BSD) sono la scelta giusta. Per raster non compressi o PNG (dopo preflate), **JPEG XL lossless batte PNG ottimizzato di circa il 48% e WebP lossless di circa il 41%** (mediana su grafica web), ma è lento in codifica.

### Cited Findings
- Confronto Xiph: FLAC sta entro circa il 3% dai codec più complessi. Tra il migliore e il peggiore lossless ci sono circa 7 punti, circa 4 tra quelli pratici. — [FLAC comparison (Xiph, copia del doc)](https://git.redump.net/hbmame/plain/3rdparty/libflac/doc/html/comparison.html)
- Test su album: OptimFROG 4.506 al 52,2% dell'originale, WavPack 4.41 high al 52,7%, FLAC 1.2.1 -5 al 53,7%. — [bobulous.org.uk, 2006](https://www.bobulous.org.uk/misc/lossless_audio_2006.html)
- Hydrogenaudio: OptimFROG circa 56,7% contro FLAC circa 60,9% (setup non chiaro). — [hydrogenaudio](https://hydrogenaudio.org/index.php?msg=425746)
- Su un file a 24 bit, FLAC ha espanso il file (circa 100,6%) mentre WavPack l'ha ridotto (circa 87,1%). La differenza è di solito sotto il 7%, ma può arrivare al 20%. — [flac-dev, 2007](https://lists.xiph.org/pipermail/flac-dev/2007-April/002174.html)
- Non ho trovato benchmark affidabili di 7-Zip (con o senza Delta) su WAV, da confrontare direttamente con FLAC.
- **Immagini (94 immagini Dribbble, 2021, MacBook Pro 2015)**, dimensione mediana con PNG di riferimento a 252 KB: OxiPNG 223 KB, OxiPNG+Zopfli 207 KB, **WebP lossless 148 KB (-41%)**, AVIF lossless 203 KB (-20%), **JPEG XL lossless 131 KB (-48%)**. Codifica mediana: WebP 3 s, JXL circa 24-25 s (cjxl 0.3.7, -E 3, effort elevato), AVIF 30 s. — [siipo.la](https://siipo.la/blog/whats-the-best-lossless-image-format-comparing-png-webp-avif-and-jpeg-xl)
- Cloudinary: libjxl 0.10 produce file più piccoli di PNG, AVIF lossless e WebP lossless sul suo test set, ma WebP lossless resta molto buono su certi tipi di immagine. — [Cloudinary, JPEG XL and the Pareto front](https://cloudinary.com/blog/jpeg-xl-and-the-pareto-front)
- Studi accademici: JPEG XL lossless supera in media la maggior parte dei codec lossless moderni. — [arXiv:2404.19755](https://arxiv.org/pdf/2404.19755)

### Inferences
- Un archiviatore **non può sostituire un PNG con un JXL** senza garantire il ritorno bit-exact al PNG. Serve una catena PNG → (preflate: raster + parametri di ricostruzione) → raster codificato JXL lossless → al ripristino decodifica JXL, ri-deflate con i parametri, PNG identico. È fattibile ma complesso. La fonte siipo usa un effort lento: per un archiviatore servono effort bassi, e il guadagno sarà minore.
- Per **WAV/AIFF** il percorso è semplice: si comprime il PCM con FLAC o WavPack e si ricostruisce l'header in modo identico, salvando i chunk non audio a parte. WinRAR e 7-Zip usano filtri delta o predittivi più deboli (nessuna misura trovata). Per l'utente Mac tipico l'audio non compresso è raro (soprattutto progetti GarageBand/Logic), quindi la priorità è bassa ma il guadagno è certo (circa 40-50%).
- TIFF/BMP/RAW non compressi (scansioni, alcuni RAW DNG non compressi) sono i candidati naturali per JXL lossless o un predittore semplice.

### Gaps
- Licenze non verificate in questa sessione. A mia conoscenza: libFLAC BSD-3, WavPack BSD-3, libwebp BSD-3, QOI MIT, OptimFROG proprietario/closed, TTA LGPL. Vanno confermate.
- Non ho trovato benchmark di QOI contro PNG/JXL in questa sessione.
- Non ho trovato misure di velocità di FLAC o JXL su Apple Silicon.

## 5. Rilevamento del tipo di dati, ordinamento per estensione/gruppi solidi, dedup a lungo raggio, preprocessing testuale

### Takeaway
L'ordinamento per tipo (7-Zip `-mqs`) e la dedup per file e CDC sono già coperti dal report precedente. In più c'è **zstd `--long`**: finestra da 128 MB fino a 2 GB, overhead minimo, output compatibile, utile su archivi grandi e ridondanti come i backup di progetti Xcode. Il preprocessing testuale (XWRT, DRT) non ha fonti primarie recenti e ha valore marginale con zstd o LZMA moderni.

### Cited Findings
- **zstd `--long` (v1.3.2)**: finestra di default di 128 MB, `--long=31` per 2 GB. In decompressione accetta 128 MB di default, oltre serve `--memory`. Il long-range matcher «aggiunge un overhead minimo», funziona con ogni livello e mantiene la velocità di decompressione. Sui tarball Linux 4.7-4.12 concatenati la finestra da 2 GB è la più veloce e comprime leggermente meglio di lrzip-zstd, mentre lrzip-xz comprime meglio di tutti. Sul tarball git il guadagno è piccolo. La memoria cresce con finestra × thread. — [zstd v1.3.2 release notes](https://github.com/facebook/zstd/releases/tag/v1.3.2)
- **7-Zip 15.06**: smette di ordinare per tipo di default e introduce `-mqs` per l'ordinamento per tipo negli archivi solidi. — [7-Zip history.txt](https://www.7-zip.org/history.txt)
- **DwarFS** (dedup + ordinamento per similarità): 0,352 GiB contro 1,219 GiB del 7z solido e 500 MB di lrzip sull'albero Perl. Le cifre sono già nel report precedente. — [DwarFS README](https://github.com/mhx/dwarfs)

### Inferences
- Per un archiviatore a blocchi indipendenti, `--long` va usato **per blocco solido grande**, oppure sostituito dalla dedup CDC globale già pianificata. Le due tecniche si sovrappongono: con dedup e ordinamento, `--long` aggiunge poco. La finestra va dichiarata nell'header per i limiti di memoria in decompressione.
- srep e lrzip sono strumenti di riferimento, non dipendenze. Non ho verificato le licenze in questa sessione: lrzip dovrebbe essere GPL, quindi incompatibile con l'inclusione in un'app MIT.
- XWRT/DRT (trasformazioni a dizionario di parole) danno il loro meglio con i compressori CM/PPM. Con LZ moderni a finestra grande il beneficio è piccolo, e i dizionari zstd addestrati coprono i file piccoli. Priorità bassa.

### Gaps
- Licenza e manutenzione di XWRT, DRT, srep: nessuna fonte primaria consultata.
- I dati numerici di `--long` nella release 1.3.2 sono solo in grafici (immagini). Non ho estratto cifre esatte.

## 6. Cosa dà più valore sui dati tipici di un utente Mac

### Takeaway
In ordine di valore atteso: (1) **ricompressione lossless dei JPEG** (circa -22% sulle foto JPEG, il tipo di file più voluminoso dopo i video); (2) **ricompressione Deflate di DOCX/XLSX/PPTX/PDF/EPUB/PNG via preflate-rs** (guadagni potenzialmente grandi, da misurare); (3) **dedup e ordinamento**, già pianificati; (4) **filtro ARM64 per slice Mach-O** (circa 5% sugli eseguibili, costo nullo); (5) audio e immagini non compressi (guadagno grande ma file rari). HEIC, HEVC, MP4 e AAC, che dominano le librerie foto e video moderne, **non hanno ricompressione lossless matura**: vanno saltati e salvati senza compressione.

### Cited Findings
- JPEG: -22/23% bit-exact (Lepton, brunsli, JXL). — [arXiv:1704.06192](https://arxiv.org/abs/1704.06192); [brunsli](https://github.com/google/brunsli); [cjxl(1)](https://man.archlinux.org/man/cjxl.1.en)
- Deflate: precomp -30% rispetto a 7-Zip Ultra sull'esempio Silesia in contenitore Deflate. Reflate stima PDF -30-50% e DOCX fino a -70% (vendor). — [precomp-cpp](https://github.com/schnaader/precomp-cpp); [PowerArchiver](https://www.powerarchiver.com/it/?p=8002)
- iWork usa Snappy (LZ debole) dentro ZIP. — [SheetJS IWA](https://oss.sheetjs.com/notes/iwa/)
- ARM64 BCJ -5% (kernel), RISC-V -7-8%. — [LKML](https://lkml.iu.edu/hypermail/linux/kernel/2407.2/04872.html)
- Audio lossless al 52-61% dell'originale. — [bobulous](https://www.bobulous.org.uk/misc/lossless_audio_2006.html); [hydrogenaudio](https://hydrogenaudio.org/index.php?msg=425746)

### Inferences
- **Matrice di compatibilità delle licenze con MIT** (da confermare dove indicato):
  - **compatibili**: liblzma (BCJ/ARM64/RISC-V; già vendorizzata), preflate-rs (Apache-2.0), lepton_jpeg_rust (Apache-2.0), precomp (Apache-2.0, ma include packJPG), libjxl (BSD-3, da confermare), libFLAC e WavPack (BSD, da confermare);
  - **da evitare come codice incluso**: packJPG (probabile LGPL), lrzip (probabile GPL), Reflate e OptimFROG (proprietari).
  - Apache-2.0 è compatibile con la distribuzione di un'app MIT, ma richiede di riportare NOTICE e licenza nei crediti.
- **Integrazione Rust**: preflate-rs e lepton_jpeg_rust sono Rust e vanno collegati via FFI C (staticlib) in XipperKit. Il costo è una toolchain Rust nella build, e Rust 1.89+ è richiesto da entrambi.
- **Maturità**: libjxl e liblzma sono maturi e mantenuti. preflate-rs e lepton_jpeg_rust sono attivi (commit recenti, CI) ma senza release. Conviene fissarli a un commit e tenere una suite di round-trip propria. precomp è di fatto in manutenzione lenta.
- **Regola d'oro per ogni trasformazione**: rilevamento per magic, trasformazione, **verifica round-trip obbligatoria in compressione**, fallback all'originale, ID trasformazione e versione nel catalogo (e nell'AAD), limiti di risorse. La decompressione deve restare deterministica tra versioni di Xipper: la versione del ricostruttore va congelata nel formato.

### Gaps
- Mancano misure sul mix reale di dati Mac (quota di JPEG vs HEIC nelle librerie Foto, quota di DOCX/PDF). Serve un benchmark interno su una home directory campione.
- Nessuna misura di throughput su Apple Silicon (M-series) per Lepton-rs, preflate-rs o il transcoding JXL. Quindi non è chiaro se queste trasformazioni siano compatibili con la modalità «veloce» o solo con «max».

# Roadmap di Xipper

Aggiornata al 02/11/2026. Le decisioni di fondo sono in [STUDIO.md](../STUDIO.md), lo stato dell'app in [FASE2.md](../FASE2.md).

**Distribuzione:** solo DMG su GitHub, firmato self-signed. Gli aggiornamenti si controllano a mano dall'app. Niente Developer ID né Mac App Store per ora.

---

## 1.0: uscita dalla beta

| # | Attività | Stato |
|---|---|---|
| 1 | Test manuali da fare a mano: Touch ID sulla password salvata, trascinamento di una voce dal browser al Finder, azioni di Comandi Rapidi | da fare (serve una persona) |
| 2 | Feedback dei tester su beta3 e beta4 e correzione delle issue | in corso |
| 3 | Nuova grafica: icone dei documenti per formato, glifo piccolo dell'icona, simbolo della barra dei menu, sfondo del DMG, illustrazione di benvenuto (prompt in [design/icon-sprite-prompt.md](design/icon-sprite-prompt.md)) | fatto: icona, simboli e sfondo del DMG (sprite A), icone dei documenti e miniature (sprite C); manca l'illustrazione di benvenuto |
| 4 | Passata finale sui testi italiani e inglesi, note di versione 1.0 | da fare |
| 5 | Controllo del marchio "Xipper" (EUIPO/UIBM/USPTO, classi 9 e 42) | da fare prima del lancio pubblico |
| 6 | Tag `v1.0.0` non pre-release: l'aggiornamento lo propone a tutti, beta comprese | ultimo passo |

Restano **fuori dalla 1.0** per scelta: RAR, ZIP Deflate64, scrittura di lz4 e brotli. XIZ è diventato stabile il 22/10/2026 (formato 1.0, vedi sotto).

---

## 2.0 — pubblicata il 23/10/2026 (v2.0.0)

### 1. ⭐ Montaggio degli archivi come volume (prima priorità)

L'archivio si apre come un volume, in lettura e scrittura: lo si sfoglia nel Finder e le app aprono i file senza estrarre. Nessun concorrente lo offre in modo nativo.

- **Spike fatto il 21/10/2026 → [FSKIT.md](FSKIT.md):**
  - il modulo si registra e si attiva, e `FSPathURLResource` (macOS 26) monta un file;
  - ma `com.apple.developer.fskit.fsmodule` è un **entitlement riservato**: con la firma self-signed AMFI rifiuta l'estensione ("No matching profile found").
- **Decisione del 21/10/2026: niente account Apple.** Si usa l'opzione C, un **server WebDAV locale** in sola lettura montato con il client di macOS.
  - Lo spike funziona: montaggio come utente, contenuto identico, si smonta da solo se il server cade.
  - Limite: il client scarica l'intero file alla prima apertura.
  - Dettagli in [FSKIT.md](FSKIT.md).
- **Stato al 23/10/2026 (✅ per la 2.0):**
  - ✅ montaggio in lettura e scrittura su WebDAV locale (classe 2) con NetFS: `xipper mount`, «Monta»/«Espelli» nel browser e nel menu del Finder;
  - ✅ formati: ZIP (anche AES, password dal Portachiavi), 7z, tar e tar compressi, XIZ, cpio, Apple Archive; gz/xz/zst/BGZF di un solo file in sola lettura;
  - ✅ file letti su richiesta (`streamEntry`), richieste Range, credenziali usa e getta per ogni montaggio, date e dimensioni come nell'archivio;
  - ✅ modifiche in un overlay copy-on-write, salvate all'espulsione con `Xipper.edit` (ZIP e XIZ senza ricomprimere il resto);
  - ✅ estrazione sicura condivisa (nomi validati, nessun symlink verso l'esterno);
  - ✅ test: overlay e whiteout, server WebDAV di classe 2, upload a blocchi, montaggio reale e smontaggio quando il server termina.
- **Dopo la 2.0:**
  - cache dei blocchi decompressi con limite di memoria (oggi tar.gz/xz senza indice si rileggono dall'inizio a ogni apertura di file);
  - 7z solidi: cache per cartella;
  - fuzzing del percorso di montaggio;
  - permessi e xattr: solo con FSKit o NFS (FSKit richiede un entitlement riservato: [FSKIT.md](FSKIT.md)).

### 2. ⭐ Ottimizzazioni in assembler ARM64/NEON e GPU — primo giro ✅ 23/10/2026

Misure in [BENCHMARK.md](BENCHMARK.md):

- ✅ **GF(2^16) di PAR2 in NEON** (tabelle di nibble e `TBL`): creazione 2,3× più veloce, output identico;
- ✅ **bzip2 decodificato a blocchi in parallelo** (ricerca del magic a 48 bit a ogni offset di bit): circa 5×;
- ✅ **xz con il ciclo ARM64 di 7-Zip** per gli stream a blocco unico: 1,31×; i multiblocco restano a liblzma multi-thread, che li sovrappone meglio;
- già accelerati, nulla da guadagnare: CRC-32 (PMULL di libdeflate), CRC-32C (istruzioni ARMv8), deflate (libdeflate), zstd (percorsi NEON propri), AES e SHA-256 (hardware via CryptoKit/CommonCrypto);
- non accelerabile con SIMD: il match finder a albero binario di LZMA (`bt_find_func`, 68% della creazione di tar.xz e 7z), limitato dalla latenza della memoria;
- GPU: nessun punto caldo dove il trasferimento si ripaghi (PAR2 in NEON fa 13 GB/s per core);
- da valutare: CRC-64 con PMULL (12% della decodifica xz a blocco unico).

Ogni ottimizzazione deve avere un percorso portabile di riserva, test di equivalenza e un benchmark in [BENCHMARK.md](BENCHMARK.md). GPU (Metal) solo dove il guadagno è misurabile, per esempio sulla compressione a blocchi indipendenti di XIZ.

### 3. XIZ stabile (v1 del formato)

**Fatto il 22/10/2026: XIZ 1.0, formato congelato, fuori dalla beta.** Specifica pubblica: [XIZ_SPEC.md](XIZ_SPEC.md).

- ✅ cifratura autenticata di dati e nomi (Argon2id, AES-256-GCM, catalogo STREAM);
- ✅ chunking basato sul contenuto (FastCDC, deduplicazione dentro i file);
- ✅ catalogo estensibile (campi TLV con bit "critico") e flag delle funzioni obbligatorie e facoltative;
- ✅ XIZ 1.1 (22/10/2026): **modifica in place** con segmenti aggiunti in coda (rinomina, elimina, aggiungi senza riscrivere nulla; `compact` per recuperare spazio);
- ✅ dati di recupero: file **PAR2** standard accanto all'archivio (vale per XIZ e per ogni altro formato);
- ✅ XIZ 1.2 (23/10/2026): **dizionari zstd** addestrati sui file piccoli (funzione obbligatoria `dictionaries`), dal livello 9: −1% su 20.000 sorgenti;
- ✅ ordinamento per somiglianza (23/10/2026): i dati vanno nei frame ordinati per estensione, nome, dimensione e percorso (come il «sort by type» di 7-Zip); −6,3% su 20.000 sorgenti, il formato non cambia. Provato anche un MinHash del contenuto: fa peggio.

### 4. Robustezza e riparazione — ✅ 22/10/2026

- ✅ dati di recupero **PAR2** scritti da zero dalla specifica (Reed-Solomon su GF(2^16)), compatibili con par2cmdline e MultiPar: `xipper par2 create|verify|repair`, «Crea dati di recupero» nell'inspector, opzione per crearli dopo ogni compressione;
- ✅ «Ripara» nella vista delle voci danneggiate quando c'è un `.par2`;
- ✅ accelerazione NEON di GF(2^16) (punto 2); da fare: ricerca dei blocchi spostati (come par2cmdline).

### 5. Modifica degli archivi — ✅ 22/10/2026

- ✅ `Xipper.edit` / `xipper edit`: elimina, rinomina, aggiungi (le cartelle si fondono), crea cartelle;
  - ZIP: le voci non toccate vengono copiate così come sono (anche AES e data descriptor), solo il nuovo viene compresso;
  - XIZ: segmento aggiunto in coda, nulla viene riscritto;
  - altri formati: ricostruiti nel loro formato e con la loro password;
- ✅ nel browser: «Rinomina…», «Elimina», «Aggiungi file…» e trascinamento di file dentro la tabella;
- ✅ il salvataggio dei volumi montati usa lo stesso percorso (ZIP e XIZ non ricomprimono più tutto);
- ✅ 7z senza ricompressione: nella 2.1 (vedi sotto).

### 6. Automazione

- Tasks MCP per i lavori lunghi;
- nuove azioni di Comandi Rapidi (monta, manifest).

### 7. Genomica

- ✅ **indici** per altri formati (23/10/2026): `.bai`/`.csi` per BAM, `.crai`, `.csi` per BCF, `.fai` (+`.gzi`), tabix per SAM; `xipper index`;
- ✅ **CRAM 3.1** in lettura e scrittura (23/10/2026: CRAM ↔ BAM con riferimento FASTA, htscodecs vendorizzato, interop con samtools; nell'app e in MCP dal 23/10/2026);
- MPEG-G: in backlog, senza data (vedi sotto).

### Rinviate

- Cartelle sorvegliate (comprimi o estrai all'arrivo): non interessano in questa fase (23/10/2026). Il progetto resta in UI_SPEC §8.6.

---

## 2.1 — pubblicata il 23/10/2026 (v2.1.0)

- ✅ **modifica di 7z senza ricompressione** (23/10/2026): un blocco (cartella 7z) i cui file sopravvivono tutti, anche rinominati, viene copiato byte per byte con i suoi coder, le chiavi AES e i CRC; un blocco che perde o sostituisce anche un solo file viene decompresso e i superstiti ricompressi insieme ai file nuovi. Nei 7z non solidi si ricomprime solo il nuovo; nei solidi solo i blocchi toccati. Restano ricostruiti i 7z a volumi;
- ✅ **ricerca dei blocchi spostati** nella verifica e riparazione PAR2 (23/10/2026), come par2cmdline: CRC-32 scorrevole su ogni offset, conferma con MD5; i dati spostati da un inserimento o una cancellazione non consumano blocchi di recupero (verifica di 512 MB: 1,2 s con uno spostamento, 1,6 s nel caso peggiore);
- ✅ **ZIP a volumi in scrittura** (23/10/2026): `xipper create -v SIZE` scrive il formato diviso di PKWARE/Info-ZIP (`nome.z01`…`nome.zip`, offset per volume, intestazioni mai spezzate; letto da 7-Zip, WinZip, WinRAR e da `zip -s 0`), oppure con `--numbered` pezzi `nome.zip.001`… che concatenati sono uno ZIP normale;
- ✅ **Deflate64** negli ZIP (23/10/2026), in lettura e in scrittura: decoder in streaming ed encoder scritti da zero (CXipShims/inflate64.c, deflate64.c: finestra 64 KiB, codici 285/30/31, blocchi dinamici/fissi/stored, file grandi a pezzi in parallelo); interop con 7-Zip e con unzip 6;
- ✅ **creazione di lz4 e brotli** (23/10/2026): tar.lz4/.lz4 a blocchi indipendenti da 4 MiB compressi in parallelo (veloce 1–2, HC 3–12) e tar.br/.br (qualità 0–11), con lz4 1.10.0 e brotli 1.2.1 vendorizzati; verificati con i tool di riferimento;
- ✅ **AES di RAR5** (23/10/2026): lettura dei RAR5 cifrati, anche con i nomi cifrati e solidi. Scritto dalla descrizione pubblica del formato (niente codice unrar): PBKDF2-HMAC-SHA256, AES-256-CBC, checksum "tweaked" con HMAC verificati da Xipper; l'archivio viene riscritto al volo nel RAR5 in chiaro che libarchive decomprime. Restano fuori i RAR 4 cifrati e i RAR5 cifrati a volumi;

---

## 2.2 — pubblicata il 25/10/2026 (v2.2.0): XIZ 1.3, accesso per cartella, sblocco k-di-n, cronologia firmata, prove, cancellazione

Funzioni che nessun formato d'archivio comune ha (scelte il 25/10/2026; spec in [XIZ_SPEC.md §13](XIZ_SPEC.md)):

- ✅ **accesso per cartella** (25/10/2026): gruppi di accesso cifrati con chiavi diverse; più destinatari, ciascuno con una password o una chiave pubblica X25519, vedono ed estraggono solo i gruppi per cui hanno la chiave (gli altri non compaiono nemmeno nell'elenco);
- ✅ **sblocco k-di-n** (25/10/2026): un gruppo si apre solo se k custodi su n danno insieme la loro credenziale (Shamir su GF(2⁸));
- ✅ **cronologia firmata** (25/10/2026): ogni modifica aggiunta all'archivio è firmata Ed25519 dal suo autore, concatenata alla firma precedente e, a richiesta, marcata temporalmente da un'autorità RFC 3161; `xipper history` mostra chi ha cambiato cosa e quando, e se la catena è integra (la verifica non richiede la password);
- ✅ **prova di appartenenza** (25/10/2026): ogni segmento si impegna su tutte le voci con un albero di Merkle (RFC 6962, foglie salate); `xipper prove` estrae la prova per un file e `xipper verify-proof` la verifica con il solo file, senza archivio né password, insieme alla firma del segmento;
- ✅ **cancellazione crittografica** (25/10/2026): negli archivi creati con `"erasable": true` ogni file ha una chiave propria in uno slot sovrascrivibile; `xipper erase` azzera lo slot e il contenuto diventa illeggibile in tutti i segmenti dell'archivio e nelle copie fatte dopo (le copie precedenti conservano la chiave); firme e prove degli altri file restano valide;
- da riga di comando (`xipper keygen`, `--access`, `--identity`, `--sign`, `--timestamp`, `history`, `erase`, `prove`, `verify-proof`);
- possibile seguito: chiavi dei file fuori dall'archivio, perché la cancellazione valga anche per le copie già fatte; chiavi P-256 nel Secure Enclave (estensione del formato).

## 2.3 — pubblicata il 29/10/2026 (v2.3.0): XIZ 1.3 nell'app, chiavi nel Portachiavi

- ✅ **nell'app** (29/10/2026): pulsante «Accesso» alla creazione (cartelle riservate, destinatari, custodi, file cancellabili, firma), scheda di sblocco con più credenziali, cronologia firmata e accesso nell'inspector, «Crea prova di appartenenza…» e «Cancella definitivamente…» nel menu contestuale, «Verifica prova di appartenenza…» nel menu Archivio, firma automatica delle modifiche;
- ✅ **chiavi nel Portachiavi** (29/10/2026): identità e chiavi di firma nel Portachiavi, con Touch ID, gestite in Impostazioni › Chiavi; la CLI le usa con `keychain:NOME` e `keygen --keychain`.

## 2.3.1 — pubblicata il 31/10/2026 (v2.3.1): correzione di sicurezza

- ✅ **link in estrazione** (31/10/2026): i symlink che escono dalla destinazione passando per altri link vengono rimossi; i link fisici non attraversano symlink già presenti nella destinazione;
- ✅ **suite di stabilità e sicurezza** (31/10/2026): uso concorrente, alberi insoliti, annullamento e troncamento in ogni punto, descrittori, link, permessi, quarantena, cifratura, WebDAV, MCP (204 test);
- ✅ generatore di password nel pannello di compressione, etichette VoiceOver sui pulsanti a icona;

## 2.4 — pubblicata il 31/10/2026 (v2.4.0): errori con azione, Apple Archive firmati, nomi per Windows

- ✅ **nomi compatibili con Windows** (31/10/2026): ZIP e 7z, opzione nell'app (attiva di default), `--windows-names` nella CLI, `windows_names` nell'MCP; i nomi già validi hanno la precedenza in caso di collisione;
- ✅ **errori con azione** (31/10/2026): quando un'estrazione o una verifica fallisce, il lavoro propone **Individua…** (parte mancante di un archivio a volumi, `Xipper.missingVolume`), **Ripara** (dati PAR2 accanto all'archivio), **Estrai altrove…** (destinazione piena, in sola lettura o senza permessi) o **Riprova** (volume scollegato);
- ✅ **Apple Archive firmati** (31/10/2026): profilo AEA 0 (ECDSA P-256, non cifrato) con una chiave derivata dalla chiave di firma XIZ e legata a essa da una firma Ed25519 nei dati autenticati; `xipper create -f aar --sign`, `xipper history --aea-pem` per verificare con `aea decrypt -sign-pub`; pulsante **Firma** nell'app e sezione Firma nell'inspector. AEA non ha un profilo con password e firma insieme;
- studio sulla firma elettronica qualificata ([reports/Studio firma elettronica qualificata.md](../reports/Studio%20firma%20elettronica%20qualificata.md)): eIDAS, CAdES/PAdES/ASiC, CSC API, roadmap;
- ✅ **pronto per il touch** (31/10/2026, v2.4.1; MacBook Pro con schermo touch, macOS 27): pulsanti a icona con area di tocco di 36 punti, pulsanti più grandi nell'inspector; le ragioni per cui Password o Firma non sono disponibili compaiono al tocco invece che solo al passaggio del mouse; chiave pubblica di chi ha firmato visibile e copiabile; menu **Azioni** nella barra del browser (le stesse voci del menu contestuale, più Seleziona tutto e **Selezione multipla** con caselle), **Estrai** con menu (Estrai in… senza ⌥), cartelle che si aprono con un tocco sulla freccia. Da provare sul dispositivo;
- seguito dall'analisi UI/UX ([reports/Analisi UI UX concorrenti macOS.md](../reports/Analisi%20UI%20UX%20concorrenti%20macOS.md)): annunci VoiceOver, altre lingue.

## 2.5 — pubblicata il 02/11/2026 (v2.5.0): sicurezza e «Cambia formato»

Dallo studio [Algoritmi e funzioni per Xipper](reports/Algoritmi%20e%20funzioni%20per%20Xipper.md). Tema della release: **nessun archivio dell'utente si perde, nessun archivio ostile passa, e si cambia formato senza ricomprimere.** I codec nuovi, la ricompressione dei JPEG e la modalità a poco spazio restano fuori (vedi in fondo).

### Fatto
- ✅ **codec aggiornati** (01/11/2026): liblzma 5.8.4 (corregge CVE-2026-34743 e GHSA-5qpq-xqfv-j9pg), libarchive 3.8.11;
- ✅ **salvataggio durevole** (01/11/2026): ogni archivio scritto va su disco con `F_FULLFSYNC` prima di prendere il nome definitivo, così un'interruzione di corrente non lascia un archivio vuoto al posto dell'originale.

### Ordine di lavoro

| Fase | Contenuto | Dipende da | Costo |
|---|---|---|---|
| **A. Banco di prova** | corpus di interop e script di verifica con i lettori esterni | — | basso |
| **B. Lettura ZIP rigorosa** | ambiguità tra parser, corpus ostile | A | basso-medio |
| **C. Quarantena e nomi ingannevoli** | test di regressione, avviso RTLO e doppia estensione | — | basso |
| **D. «Cambia formato» v1** | motore, CLI, app | A, B (e il salvataggio durevole, fatto) | medio |
| **E. Piccole cose** | codifica dei nomi ZIP, manifest dei codec, filtro ARM64 misurato | — | basso |
| **F. Rilascio** | test completi, note, DMG | tutte | basso |

C ed E si possono fare in parallelo ad A–D.

#### A. Banco di prova — ✅ fatto (01/11/2026)
Serve a B e D, e resta per le release successive.
- ✅ **corpus** in `Tests/XipperKitTests/Fixtures/interop/` (46 archivi, 788 KB, solo contenuto sintetico), prodotto da `scripts/make-interop-corpus.sh`. Contiene archivi di Info-ZIP (anche ZipCrypto, ZIP64, data descriptor), Finder/ditto con `__MACOSX`, 7-Zip (ZIP Deflate/Deflate64/BZip2/LZMA/PPMd/AES; 7z LZMA/LZMA2 solido e non, PPMd, BZip2, Deflate, Copy, filtro ARM64, AES con e senza nomi cifrati, volumi), bsdtar (pax, ustar, gnutar, newc, odc, zip, 7z, tar.gz/bz2/xz), zstd con finestra lunga e più frame, xz multiblocco e multistream, gzip multimembro, bzip2 multistream, lz4, brotli, Apple Archive (lzfse, lzma, zlib, raw), un nome CP437 senza flag UTF-8. `InteropCorpusTests` verifica ed estrae ognuno e confronta albero, contenuti, link e bit di esecuzione.
- ✅ **`scripts/interop.sh`**: crea con Xipper ogni tipo di archivio che scrive (ZIP in 7 metodi, AES, ZIP64, volumi; 7z solido, non solido, AES, nomi in chiaro, volumi; tar e varianti, cpio, aar, file singoli) e lo fa verificare ed estrarre da `7zz`, `unzip`, `ditto`, `bsdtar`, `gzip`, `bzip2`, `xz`, `zstd` e `aa`, confrontando l'albero estratto: 61 controlli, 0 errori.
- **Trovato:** Xipper non legge gli ZIP con metodo 98 (PPMd variante I, scritto da 7-Zip con `-mm=PPMd`); il 7z PPMd (variante H) sì. Il test lo segnala e fallirà quando funzionerà → aggiunto in E. L'`unzip` di macOS non ha bzip2: non è un problema di Xipper.
- Mancano archivi scritti da WinRAR ed Esplora risorse (servono le macchine Windows).

#### B. Lettura ZIP rigorosa — ✅ fatto (01/11/2026)
Un ZIP che lettori diversi interpretano in modi diversi viene rifiutato con «ambiguous ZIP», invece di sceglierne un'interpretazione. C'era già il controllo delle voci sovrapposte (`ZipReader.checkOverlaps`). Ora in più:
- ✅ un solo record di fine archivio che arriva esattamente alla fine del file: un secondo nascosto nel commento → rifiutato; i byte aggiunti dopo l'archivio restano tollerati;
- ✅ il numero di voci del record di fine deve coincidere con quelle del central directory, e dopo l'ultima voce non può esserci altro (solo la firma digitale facoltativa); tollerato il contatore a 16 bit che riparte da 0 oltre le 65535 voci, nei vecchi ZIP senza ZIP64;
- ✅ record ZIP64 coerente con quello classico: un campo che il classico non segna come «vedi ZIP64» deve avere lo stesso valore;
- ✅ header locale uguale al central directory: nome, metodo, cifratura e, senza data descriptor, CRC e dimensioni;
- ✅ nomi: NUL rifiutato; due voci con lo stesso percorso (anche NFC e NFD) rifiutate; flag UTF-8 più un nome Unicode Info-ZIP diverso rifiutato. I nomi che differiscono solo per le maiuscole restano validi: in estrazione su un volume che non distingue le maiuscole si tengono entrambi («A 2.txt»);
- ✅ nella verifica (`xipper test`, Verifica nell'app): header locali nascosti negli spazi tra le voci, che solo i lettori in streaming vedono;
- ✅ test: `ZipAmbiguityTests` con un ZIP costruito byte per byte per ogni caso, più le varianti legittime (commento, byte in coda, ZIP64 coerente); nessun falso positivo sul corpus di interop né su 122 ZIP, documenti Office, EPUB e JAR veri presenti sul Mac.
- Non fatto: il confronto con l'elenco completo dei 14 tipi di ZipDiff (serve il testo integrale dell'articolo). La firma «sui byte estratti» non riguarda ZIP: Xipper firma solo XIZ e Apple Archive.

#### C. Quarantena e nomi ingannevoli — ✅ fatto (01/11/2026)
- ✅ **buco chiuso: volume montato.** I file di un archivio montato non avevano la quarantena: un'app scaricata, aperta dal volume, saltava Gatekeeper (la classe di CVE-2022-42821 di Archive Utility). Ora il server WebDAV presenta accanto a ogni file e cartella un «._nome» AppleDouble con la quarantena dell'archivio, che il client WebDAV di macOS legge come attributo esteso. Il valore è identico a quello dell'archivio: copyfile lo riscriverebbe nella forma interna «q/…», quindi viene impacchettato con un nome sostitutivo poi scambiato. Rispetta la preferenza dell'app; in CLI `xipper mount --no-quarantine`;
- ✅ **test di regressione** (`QuarantineTests`): estrazione in ZIP, 7z, tar.zst, Apple Archive, XIZ e cpio con quarantena su file, cartelle e link; archivio senza quarantena o con la propagazione spenta; archivi annidati, anche al secondo livello (CVE-2025-0411 di 7-Zip); elementi preparati per Quick Look e trascinamento; quarantena salvata *dentro* un Apple Archive (anche con il flag «approvato dall'utente») mai ripristinata; volume montato, sia nel server sia con un montaggio reale;
- ✅ **nomi ingannevoli** (`DeceptiveName`): caratteri di controllo bidirezionali (RTLO e simili), estensione di documento davanti a una eseguibile (`fattura.pdf.app`, `foto.jpg.command`, `invoice.docx.exe`), spazi che nascondono l'estensione vera. Non blocca l'estrazione, avvisa: un banner nel browser con i nomi reali (`⟨U+202E⟩` visibile), il «Nome reale» nell'inspector con la spiegazione, il riepilogo del lavoro dopo l'estrazione e un `warning:` della CLI;
- verificato: le altre vie che fanno uscire file dall'archivio (anteprima, trascinamento, archivi annidati, MCP) usano già la propagazione; l'anteprima Quick Look dell'estensione legge i dati in memoria e non crea file.

#### D. «Cambia formato» v1 — ✅ fatto (02/11/2026)
Converte un archivio in un altro formato copiando i dati compressi così come sono dove i due formati hanno lo stesso codec, e ricomprimendo il resto. Il nuovo archivio viene scritto con un nome temporaneo accanto alla destinazione, verificato e solo allora prende il suo nome; l'originale non viene mai modificato.
- ✅ **piano** (`Xipper.conversionPlan`): per ogni file dice se è *copiato* o *ricompresso* e perché (metodo che il formato di arrivo non ha, blocco solido, voce cifrata, metadati macOS da unire…), lo spazio libero necessario e cosa si perde (firme XIZ e AEA, gruppi di accesso XIZ, password, dati PAR2 accanto all'originale);
- ✅ **copia senza ricomprimere:** ZIP → 7z per store, Deflate, Deflate64 e bzip2 (ogni voce diventa una cartella 7z non solida con quel codec); 7z → ZIP per le cartelle non solide con un solo file in quei metodi. Andata e ritorno ZIP → 7z → ZIP: i byte compressi di ogni voce sono identici a quelli dello ZIP di partenza;
- ✅ **tutto il resto ricompresso** con le impostazioni del formato di arrivo (tar.*, XIZ, Apple Archive, cpio, 7z solidi, RAR). Le voci da ricomprimere vengono estratte una volta in una cartella di lavoro accanto alla destinazione: la v1 non le ricomprime in streaming, e lo spazio necessario lo mette in conto;
- ✅ **cifratura:** con la password dell'originale le voci vengono decifrate; un archivio di arrivo con password ricomprime tutto (i dati in chiaro non si copiano dentro un archivio cifrato);
- ✅ **sicurezza:** verifica completa del nuovo archivio (test, più stessi percorsi, dimensioni e CRC dell'originale) prima del rename; `F_FULLFSYNC` su file e cartella; mai sovrascrivere una destinazione esistente senza `--overwrite`; un processo ucciso a metà (SIGKILL) lascia l'originale intatto e nessun file con il nome di destinazione, e la conversione successiva ripulisce la sua cartella di lavoro; a richiesta l'originale va nel Cestino, solo dopo la verifica;
- ✅ **trovato e corretto durante i test:** il lettore 7z di Xipper non decodificava il Deflate64 (la verifica ha bloccato la conversione invece di produrre un archivio illeggibile): ora sì;
- ✅ **CLI** `xipper convert ARCHIVIO --to FMT [-o FILE] [--dry-run] [--json] [--encrypt] [--trash-original] [--accept-losses]`; **MCP** `archive_convert` (con `dry_run`); **app**: «Cambia formato…» nel menu Azioni del browser, con un foglio che mostra il piano prima di partire e il lavoro nel pannello dei lavori;
- ✅ **test** (`ConvertTests`): 4 metodi ZIP → 7z → ZIP con payload identici, `7zz t` e `unzip -t` sui risultati, 7z solido → ZIP, tar.xz verso 7 formati con l'albero identico, password in entrambi i versi, destinazione esistente, annullamento, processo ucciso in 4 momenti diversi;
- spostato alla v1.5: ZIP zstd → XIZ senza ricomprimere (XIZ calcola SHA-256 e deduplica sui dati in chiaro, quindi serve almeno la decodifica) e il ricomprimere in streaming senza cartella di lavoro;
- da provare a mano: il foglio nell'app (compila, ma non l'ho aperto a schermo).

#### E. Piccole cose — ✅ fatto (02/11/2026)
- ✅ **ZIP PPMd (metodo 98):** decoder PPMd variante I dell'LZMA SDK 26.05 (`Ppmd8.c`, `Ppmd8Dec.c`, pubblico dominio) con una sorgente «a richiesta» sui byte della voce, anche cifrati AES o ZipCrypto. Provato su archivi di 7-Zip a -mx=1, 5, 9 e con AES-256; il caso del corpus di interop, prima segnato come non supportato, ora si legge;
- ✅ **codifica dei nomi ZIP:** i nomi senza flag UTF-8 non sono più letti sempre come CP437. Xipper indovina la code page dall'insieme dei nomi, con un punteggio sulla struttura dei byte di ogni candidata (CP437, CP866, Shift-JIS, GBK, Big5, EUC-KR), e tiene CP437 se nessuna è chiaramente migliore. EUC-KR e GBK hanno la stessa struttura: a parità decide la lingua del Mac. Il riconoscimento di Foundation, provato prima, sbagliava russo e occidentale. Scelta a mano nell'app (menu Azioni › Codifica dei nomi, solo per gli ZIP che ne hanno bisogno) e da CLI con `--names-encoding`, anche con Windows-1252/1251 e CP850. Il corpus di interop ora ha nomi davvero senza flag: il vecchio «CP437» di Python aveva in realtà il flag UTF-8;
- ✅ **manifest dei codec** (`Vendor/MANIFEST.json`, `scripts/make-vendor-manifest.py`): versione, sorgente e SHA-256 di ognuno dei 511 file vendorizzati, con i file nostri segnati; `VendorManifestTests` fallisce se un file cambia, manca o si aggiunge senza rigenerare il manifest;
- ✅ **filtro ARM64 nei binari universali: misurato, nessun cambiamento.** Su 8 binari universali di app installate (123 MB), con 7z -mx=9 e rispetto a nessun filtro: ARM64 su tutto il file (quello che fa Xipper) −6,1%; filtri per architettura compressi separatamente −1,8% (si perde la ridondanza tra le due parti); ARM64 solo sulla parte arm64 +4,2%. Il comportamento attuale è il migliore. Per XIZ 1.4 il filtro per architettura va valutato solo dentro un unico flusso compresso.

#### F. Rilascio — ✅ (02/11/2026)
- ✅ 250 test automatici e i 61 controlli di `scripts/interop.sh`;
- ✅ testi italiani e inglesi, note di versione, DMG 2.5.0;
- da provare a mano dopo l'uscita: il foglio «Cambia formato…», il menu «Codifica dei nomi», il banner dei nomi ingannevoli su un archivio vero, un'app aperta da un volume montato (Gatekeeper deve chiedere conferma).

### Fuori dalla 2.5
Spostato nelle versioni qui sotto: «Cambia formato» v1.5 e v2, XIZ 1.4, banco di misura, ricompressione JPEG, recovery record in XIZ, riparazione ZIP, decoder isolati.

---

## Prossime versioni

Aggiornato il 02/11/2026, dallo studio [Algoritmi e funzioni per Xipper](reports/Algoritmi%20e%20funzioni%20per%20Xipper.md) e da quello che la 2.5 ha lasciato aperto. Le versioni sono un ordine di lavoro, non date. Regola che viene dalla 2.5: **prima si misura, poi si sceglie.** Due idee dello studio non hanno retto alla prova: il filtro ARM64 per architettura e il riconoscimento delle code page di Foundation.

### 2.5.1 — pubblicata il 02/11/2026 (v2.5.1): prove a mano e correzioni
- **prove a mano**:
  - ✅ codifica dei nomi, provata dal proprietario con gli ZIP di prova (02/11/2026);
  - da fare con il kit in `dist/test-2.5.1/` (con istruzioni in `LEGGIMI.txt`, fuori dal repo): banner dei nomi ingannevoli, Gatekeeper su un'app aperta da un volume montato, foglio «Cambia formato…» su ZIP e 7z solido;
- ✅ **147 archivi «veri» dai test di libarchive 3.8.11** (WinZip AES in 6 metodi, PKWARE, 7-Zip, jar, nomi CP866/CP932, SFX, casi malformati e di fuzzing) in `Fixtures/libarchive`, con `LibarchiveVectorTests`: quelli validi devono passare, quelli malformati vanno rifiutati senza crash, come in libarchive. Problemi trovati e corretti:
  - un 7z **vuoto** era rifiutato come «scrittura interrotta»: ora si distinguono dal CRC;
  - filtro **IA64** nei 7z, mancante;
  - **7z autoestraenti** (.exe e ELF) non riconosciuti: ora si aprono, si verificano e si convertono; modificarli è rifiutato, perché si perderebbe il programma;
  - il controllo «ambiguo» della 2.5 rifiutava un nome diverso tra header locale e central directory anche quando il nome Unicode (0x7075) dell'header locale è proprio quello del central directory: ora è accettato, gli altri casi restano rifiutati;
  - messaggio più chiaro per un central directory cifrato (PKWARE strong encryption, non supportata);
- ✅ uno ZIP senza record di fine archivio (`extra_padding.zip`), che libarchive legge come flusso: Xipper lo rifiuta ancora all'apertura, ma `xipper repair` lo ricostruisce (2.6);
- archivi scritti da WinRAR ed Esplora risorse: servono ancora una VM Windows o un tester.

### 2.6 — pubblicata il 02/11/2026 (v2.6.0): banco di misura, XIZ 1.4, «Cambia formato» v1.5
1. ✅ **Banco di misura**: `swift run -c release xipper-bench` su un corpus Mac vero di 735 MB (binari delle app, sorgenti, documenti, testo strutturato, foto), solo in locale. Risultati in `docs/BENCHMARK.md` («Codec per XIZ 1.4»). zxc, bsc e kanzi non sono stati misurati (lzbench non compilato).
2. ✅ **XIZ 1.4** (decisione del 02/11/2026: **solo LZMA2**, il formato resta aperto):
   - LZMA2 (codec 2) per la modalità «massima»: −10% sui binari e −3% sui sorgenti rispetto a zstd 19, ma decompressione circa 10 volte più lenta. Nell'app è un'opzione delle Impostazioni (XIZ › Livello «Massimo» con LZMA2), da riga di comando `--lzma2`;
   - filtro ARM64 + LZMA2 (codec 3) per i frame fatti per lo più di eseguibili arm64, su tutto il frame: un solo flusso compresso, come misurato (−6,1% contro −1,8% per architettura);
   - niente codec «veloce»: zstd decomprime già a 1,4–2,9 GB/s per core e i frame vanno in parallelo, più dell'SSD. LZ4 farebbe archivi molto più grandi (binari: 47% contro 31%);
   - niente filtro x86: su Apple Silicon i binari sono arm64 o universali, e per gli universali il filtro ARM64 su tutto il file è risultato il migliore;
   - compatibile all'indietro: un lettore 1.3 rifiuta l'archivio con un messaggio chiaro (bit richiesto `lzma2`, spec §14).
3. **«Cambia formato» v1.5:**
   - ✅ coppie con sola intestazione nuova, senza ricomprimere:
     - ZIP LZMA ↔ 7z LZMA: le 5 proprietà passano dall'intestazione ZIP al coder 7z e viceversa. Verso ZIP, il flusso viene decodificato una volta per sapere se ha il marcatore di fine (bit 1), che 7-Zip controlla;
     - 7z LZMA2 → ZIP xz (metodo 95): un contenitore xz costruito attorno ai dati LZMA2, con controllo CRC-32, che è quello del 7z;
     - ZIP Deflate/bzip2/zstd/xz → tar.gz/.bz2/.zst/.xz: ogni file copiato diventa un membro del flusso compresso (un membro gzip con CRC e dimensione dello ZIP, un flusso bzip2, zstd o xz intero);
   - ✅ ZIP zstd → XIZ: ogni voce fino a 64 MiB diventa un frame XIZ così com'è. La voce viene decodificata una volta, per lo SHA-256 e per il controllo con il CRC dello ZIP; una voce con più frame zstd viene ricompressa da quella copia;
   - ✅ interop: `7zz t`, bsdtar, GNU/BSD tar, `gzip -t`, `bzip2 -t`, `zstd -t`, `xz -t` passano su tutte le coppie nuove, anche con file da 100 MB. Archive Utility va ancora provato a mano;
   - ✅ ricompressione in streaming verso tar, tar.gz/.bz2/.xz/.zst/.lz4/.br: l'estrattore del formato di partenza scrive ogni voce direttamente nel nuovo tar (`TarStream`, tramite un `ExtractionRedirect` di `ExtractionContext`), senza cartella di lavoro. Lo spazio necessario è solo quello del nuovo archivio. Restano con la cartella di lavoro: le destinazioni ZIP, 7z, XIZ e AAR (i loro writer rileggono i file) e le sorgenti con metadati AppleDouble o hard link;
   - ✅ corretto: i metadati macOS (`__MACOSX/._file`) delle voci ricompresse non venivano estratti con i loro file, quindi tag e xattr si perdevano nel nuovo archivio (difetto della 2.5);
4. **Piccole funzioni attese da chi viene da Windows e Linux:**
   - ✅ **riparazione ZIP senza PAR2** (`Xipper.repairZip`, `xipper repair`, pulsante «Ricostruisci» nell'app):
     - il central directory viene ricostruito dagli header locali, trovati scorrendo il file; con il data descriptor la fine dei dati si accetta solo dove la dimensione del descriptor coincide;
     - le voci si copiano senza ricomprimere; permessi, link e commenti si recuperano dai resti del central directory, quando ci sono;
     - il nuovo ZIP, «nome (riparato).zip», viene verificato prima di prendere il nome, e le voci che non passano il CRC sono scartate; l'originale non si tocca;
     - provato su ZIP troncati, central directory cancellato, dati rovinati, ZIP «stored» dentro uno ZIP, ZIP di ditto con data descriptor e `extra_padding.zip` di libarchive;
   - ✅ **estrazione ricorsiva** (`ExtractOptions.nestedDepth`, `xipper extract -r [N]`, Impostazioni › Generali): gli archivi trovati tra i file estratti vengono estratti accanto a sé, fino a 3 livelli, e tolti se l'estrazione è pulita. La quarantena passa da un livello all'altro. Restano come sono: BGZF e `.gz` genomici, parti di archivi divisi, documenti che sono ZIP (docx, jar). Un archivio interno danneggiato resta al suo posto ed è segnalato;
   - ✅ **strumento di hash** (`xipper hash`, «Calcola/Verifica checksum…» nel menu File, «Esporta checksum…» dopo la verifica di un archivio):
     - algoritmi: SHA-256, SHA-512, SHA3-256 (CryptoKit), BLAKE3, XXH3-64, XXH3-128, SHA-1, MD5, CRC-32, CRC-32C; più algoritmi in una sola lettura;
     - BLAKE3 scritto in C dalla specifica (`CXipShims/blake3.c`), con NEON a 4 chunk e sottoalberi da 1 MiB su tutti i core: 5,6 GB/s su M3 Max (SHA-256 2,5 GB/s). Controllato con i vettori ufficiali e con un'implementazione indipendente in Python fino a 48 MiB. XXH3 dallo `xxhash.h` di zstd, senza l'adattamento che lo spegne;
     - liste nel formato di `sha256sum`/`b3sum` (con l'escape dei nomi), righe BSD (`SHA256 (file) = …`) con più algoritmi, JSON DRS; la verifica capisce tutti e tre e prende l'algoritmo dal nome (`B3SUMS`, `.sha3-256`…);
     - checksum dei file dentro un archivio senza estrarlo (`--contents`), anche per i 7z;
   - ✅ **«Copia come comando»** (menu contestuale dei lavori, pannello di fine compressione): il lavoro diventa il comando `xipper` equivalente, con le stesse impostazioni dell'app, gli argomenti tra apici per la shell e `-p` al posto della password, che non viene mai scritta. Quello che la riga di comando non sa esprimere (conflitti chiesti uno per uno, soglia anti-bomba diversa, gruppi d'accesso XIZ) finisce in commenti `#` sopra il comando. Per arrivarci la CLI ha nuove opzioni: `--flatten`, `--apple-double`, `--recompress-all`, `--no-bgzf`, `--bgzf-index`, `--zipcrypto`.

### 2.7 — recupero dentro l'archivio, decoder isolati
- ✅ **recovery record dentro XIZ** (XIZ 1.5, spec §15; 03/11/2026):
  - Reed–Solomon di Cauchy su GF(2^16) (il campo e il kernel NEON di PAR2) a fette fisse di tutto l'archivio, superblock e footer compresi: qualsiasi danno fino a M fette si ricostruisce, senza password. Header e tabella degli hash in due copie più un trailer; il record sta dopo l'ultimo footer, così ogni lettore dalla 1.1 lo salta (come la coda di un append interrotto) e nessun bit di formato cambia;
  - circa 2.000 fette (minimo 4 KiB), 10% predefinito: su 2 GB il record si scrive in 3,2 s e 150 punti danneggiati si riparano in 2,8 s (M3 Max), riparazione in place verificata con gli hash prima di scrivere;
  - `xipper create --recovery N`, `xipper scrub [--repair]`, `xipper recovery add|remove|info`, `xipper repair a.xiz`; le modifiche (append) riscrivono il record;
  - app: «Dati di recupero dopo ogni compressione» mette il record dentro gli XIZ, «Ripara» lo usa, verifica mensile facoltativa in background degli archivi seguiti (Impostazioni › Generali) con riparazione automatica e notifica; un XIZ col superblock rovinato si riconosce dal trailer;
  - libxiz: stesse funzioni in C (`xiz scrub`, `xiz recovery`); i record delle due implementazioni sono identici byte per byte;
  - PAR2 resta per gli altri formati.
- **decoder isolati:** RAR (libarchive), 7z e i formati futuri in un servizio XPC sandboxed, così un bug di memoria in un decoder esterno non tocca l'app;
- **ricompressione JPEG** (circa −22% senza perdita, byte per byte): JPEG XL o lepton_jpeg_rust come blob verificato in XIZ, dopo aver controllato licenza e toolchain e misurato la velocità su Apple Silicon;
- **accessibilità e lingue** (dall'analisi UI/UX): annunci VoiceOver per i lavori, altre lingue oltre italiano e inglese.

### 3.0 — poco spazio, post-quantum
- **«Cambia formato» v2, con poco spazio libero:**
  - registro delle operazioni, `F_PUNCHHOLE` sull'originale, ripresa e ritorno all'originale prima del primo punching;
  - riconoscimento di istantanee e cloni APFS, ripiego a file numerati;
  - esce solo dopo i test di interruzione di corrente in una VM macOS su immagini APFS. Apple non documenta come `F_PUNCHHOLE` e `rename` si comportano in quel caso.
- **ricompressione dei flussi Deflate** dentro Office, EPUB, PDF e PNG (preflate-rs), FLAC per WAV/AIFF: dopo il banco, con i parser in un processo isolato;
- **LZRAVEN e LZMESH** di Apple come codec XIZ facoltativi, solo su macOS 27 e successivi (decisione del 02/11/2026). Il banco li ha confermati: LZRAVEN comprime come o meglio di LZMA2 (binari 20,8% contro 23,7%) e decomprime circa 3 volte più veloce; LZMESH comprime come zstd 9 alla velocità di zstd 3. Limiti da gestire: esistono solo nelle librerie di Apple, quindi gli archivi non si aprono su macOS 26 né con i lettori XIZ per altri sistemi (bit richiesto a parte, avviso chiaro alla creazione);
- **snapshot XIZ montabili per versione**, sul modello di zpaq e restic: i pezzi ci sono già (segmenti firmati, montaggio);
- **destinatario ibrido X25519 + ML-KEM-768**, compatibile con age (`age1pq1…`), se CryptoKit lo offre;
- **OpenZL** per i frame strutturati (CSV, Parquet, tabelle genomiche), quando il formato si stabilizza.

### 3.1 — XIZ forense
Analisi e progetto in [FORENSE_3.1.md](FORENSE_3.1.md): acquisizione di dischi e volumi da `/dev/rdiskN` in un XIZ verificabile, firmato e datato, con catena di custodia come segmenti firmati in coda. Lacune principali da colmare:
- metadati forensi: record del caso e del dispositivo, log di acquisizione, mappa dei settori illeggibili, hash della sorgente (MD5, SHA-1, SHA-256) firmati;
- identità di chi firma: oggi Ed25519 con un'etichetta libera; servono certificati X.509 o smart card e una TSA qualificata;
- verifica crittografica delle letture a offset casuali: tabella SHA-256 dei frame con radice Merkle.

Gli aspetti legali vanno fatti verificare a un esperto prima di qualsiasi uso.

### Aperti, senza versione
- confronto voce per voce con i 14 tipi di ambiguità di ZipDiff (serve il testo integrale dell'articolo);
- licenze da verificare prima di qualsiasi uso: lzav, kanzi, libbsc, lzham, bzip3 (forse LGPL), packJPG (forse LGPL), libjxl, libFLAC, WavPack.

### Da non fare
Creare RAR, ZPAQ, ARC o PEA; autoestraenti (SFX); recupero password a forza bruta; cancellazione sicura su SSD; codec neurali, troppo lenti (pochi KB/s). Le ragioni sono nello studio.

---

## XIG: profilo genomico nativo di XIZ

- ✅ **decisione** (23/10/2026): opzione (b) dello studio genomico, con il rischio brevettuale accettato dal proprietario; disegno in [XIG_DESIGN.md](XIG_DESIGN.md);
- X1 prototipo Swift e benchmark B3 (soglia: ≥5% meno di CRAM 3.1 normal); X2 spec XIZ 1.3; X3 Xipper completo; X4 libxiz in C con plugin htslib; X5 lettori Java e Python;
- ✅ **decisioni** (23/10/2026, [XIG_DESIGN.md §11](XIG_DESIGN.md)): estensione `.xig` per gli archivi genomici e `.xiz` per gli altri; Java puro (codec di htsjdk), Python puro con binding nativo solo per i codec; FASTQ in backlog; slice 10k e span 10 provvisori; mate collegati se cadono nella stessa slice, come CRAM 3.0;
- primo benchmark sul BAM reale (chr20, 6,6 M letture, senza riferimento): XIG 106,6 MB contro CRAM 3.1 normal 106,7 MB e archive 91,7 MB, con lo scrittore di prova in Java; mancano le misure con riferimento e i mate collegati;
- lettore XIG per IGV, in una sessione separata (branch `xig` di un fork locale, non pubblicato): **fermo** su richiesta del proprietario.

---

## Formati in sola lettura

- ✅ **RAR/RAR5** in sola lettura (23/10/2026, anticipato dalla 3.0), con i lettori di libarchive (BSD-2) e l'estrazione sicura di Xipper, volumi multipli compresi; RAR5 cifrati dalla 2.1.

## Backlog (senza data)

Decisione del 23/10/2026: questi formati escono dalla 3.0 e restano in backlog, senza versione né data.

- **ISO 9660/UDF** e **DMG** non cifrati;
- **MPEG-G** in sola lettura, fase 1 (rischio brevettuale accettato dal titolare il 23/10/2026): riconoscimento, info, verifica ed esportazione in SAM/BAM/FASTQ/CRAM estendendo Genie. Studio tecnico in [MPEGG_STUDY.md](MPEGG_STUDY.md), stima 35–50 giorni-persona; decisioni aperte nella §7 dello studio.

---

## Principi che valgono per ogni versione

- Nessuna dipendenza esterna a runtime: i codec restano compilati dentro l'app.
- L'estrazione sicura è condivisa da tutti i formati e da FSKit; ogni nuovo lettore entra nel fuzzing.
- Ogni funzione arriva con test automatici; quello che si può provare solo a mano viene annotato in FASE2.md.

# Zipper: studio di fattibilità

Archiviatore nativo per macOS su Apple Silicon (arm64)

*Versione 0.1, 21 ottobre 2026. Bozza di studio, nessuna riga di codice ancora scritta.*

---

## 0. Sintesi

| Tema | Conclusione |
|---|---|
| **Nome "Zipper"** | ⚠️ **Sconsigliato come nome commerciale.** È molto usato nello stesso ambito (archiviatori), anche su macOS. **Candidato alternativo: "Xipper"**, molto più pulito (§1.4). |
| **Fattibilità tecnica** | Alta. macOS mette a disposizione buona parte del necessario (Compression, AppleArchive, CryptoKit/CommonCrypto, zlib/bzip2 di sistema). Il resto si scrive o si incorpora come sorgente. |
| **"Totalmente autoincluso"** | Si può fare: un solo `.app`, nessun Homebrew, nessun binario esterno, nessun download a runtime. La scelta da prendere è se incorporare codec open source con licenza permissiva (compilati dentro l'app) o scriverli tutti da zero. Raccomandazione al §3. |
| **Ottimizzazione arm64** | Il guadagno vero viene dal parallelismo sui P-core e gli E-core, dalle istruzioni CRC32/AES/SHA hardware di ARMv8, da NEON e dall'I/O con mmap e APFS clone. Dettagli al §5. |
| **Integrazione di sistema** | Finder Sync (menu contestuale), Quick Look (anteprima del contenuto), App Intents (Comandi Rapidi/Shortcuts e Azioni rapide), Servizi, CLI inclusa e, come obiettivo avanzato, montaggio dell'archivio come volume con FSKit. Dettagli al §6. |
| **Licenza** | **Gratuito e open source, licenza MIT** (§10). |
| **Distribuzione** | **Decisione del 21/10/2026: solo DMG su GitHub, firmato self-signed.** Developer ID e notarizzazione non servono per ora; il Mac App Store è escluso (la sandbox limiterebbe l'estrazione "accanto al file", l'estensione del Finder e il server MCP). Dettagli al §8. |

---

## 1. Analisi del nome "Zipper"

### 1.1 Usi esistenti trovati

| Prodotto | Tipo | Ambito | Conflitto |
|---|---|---|---|
| **Zipper.app** (GNUstep) | Archive viewer GPLv2, ultima versione 1.5 (2013) | Desktop Unix/GNUstep, apre tar/gz/bz2/rar/lha/zip | 🔴 Stesso nome *e* stesso bundle name `Zipper.app`. Progetto fermo ma pacchettizzato in Debian. |
| **unxed/zipper** | CLI Go, sostituto di tar/zip/unzip, zstd, ZIP cifrati con lista file nascosta, modalità di estrazione "resiliente" | CLI multipiattaforma, **attivo** (v0.1.x pubblicate di frequente) | 🔴 Stesso nome, stessa funzione, progetto vivo. Conflitto anche per il nome del comando `zipper`. |
| **Mr. Zipper – 7Z RAR 7ZIP** (TinySoft) | Archiviatore a pagamento | **Mac App Store** | 🟠 Molto vicino: un utente lo confonde facilmente. |
| **Smart Zipper / Smart Zipper Pro** (Zip-Rar Inc) | Archiviatore ZIP/RAR/7z | Mac | 🟠 Molto vicino. |
| **Password Zipper** | ZIP con password | Mac App Store | 🟠 Molto vicino, stessa feature chiave (le password). |
| **"Zipper"** (citato nella scheda "ZIP Extractor – UnZIP, UnRar") | Archiviatore RAR/7z/ZIP con password | App Store iPad | 🟠 Possibile omonimo esatto sull'App Store Apple. |
| **UnZipper**, **iZipper**, **Zippr** (AppYogi) | Archiviatori | Mac/App Store | 🟡 Varianti dello stesso nome. |
| **Zipper 1.9.8** | Software di sviluppatore ignoto, segnalato da JVN (CERT giapponese) | Windows/sconosciuto | 🟡 Esiste un omonimo con un avviso di sicurezza associato: brutto per la reputazione nei motori di ricerca. |
| **Mail Zipper** (LRM) | Cifratura email | Giappone | 🟢 Ambito diverso. |
| **zypper** (openSUSE) | Package manager | Linux | 🟢 Simile solo nel suono, ma inquina le ricerche. |
| "zipper" (struttura dati funzionale), vari pacchetti npm/crates | Librerie | Sviluppo | 🟢 Rumore SEO. |

### 1.2 Marchio

- Nelle ricerche fatte non è emersa una registrazione del marchio "ZIPPER" in classe 9 (software) per la compressione. Esiste invece "IZIP" (Comc Soft Corp., registrato nel 2012 e rinnovato) per software di gestione di file compressi.
- "Zipper" per un archiviatore è un termine **descrittivo e generico**: l'icona dei file ZIP è proprio una cerniera. Un marchio descrittivo è difficile da registrare e da difendere.
- **Da fare prima di qualsiasi lancio:** ricerca formale su EUIPO (TMview), UIBM e USPTO in classe 9 e 42, più un controllo dei nomi esatti su Mac App Store (App Store Connect rifiuta i nomi già in uso).

### 1.3 Verdetto e alternative

**Verdetto:** "Zipper" va bene come **nome in codice interno** (repo, target Xcode). **Non va bene come nome di prodotto**, per quattro motivi:
1. ci sono almeno due omonimi esatti nello stesso ambito, uno dei quali attivo (la CLI `zipper`);
2. ci sono 4 o 5 app Mac con nomi quasi identici;
3. il nome non è difendibile come marchio;
4. un prodotto nuovo con un nome così affollato sarebbe quasi introvabile in ricerca.

**Spunti per alternative**, tutti **ancora da verificare** con lo stesso metodo:
- *Cerniera*: "zipper" in italiano, distintivo all'estero, con un gioco di parole che resta.
- *Bale*, *Crate*, *Satchel*, *Hold*: richiamano il contenitore. Probabilmente alcuni sono già usati.
- *Ripstop*, *Tessera*, *Ark* (già usato da KDE, quindi da evitare).
- Una parola inventata (stile "Keka"), la più facile da registrare.

### 1.4 Candidato "Xipper" (verifica del 21/10/2026)

| Verifica | Esito |
|---|---|
| App o prodotto "Xipper" (web, App Store) | 🟢 Nessun archiviatore né app trovati con questo nome |
| GitHub | 🟠 **JayBrown/Xipper**: workflow macOS e script shell per creare, firmare e verificare archivi `.xip`. Stessa piattaforma e stesso ambito, ma piccolo (10 stelle) e non è un'app. Gli altri risultati sono repo personali (backend/frontend "Xipper", un esercizio di selezione) e una libreria Elixir "Huet's zipper". |
| Somiglianze | 🟡 *Sxipper*: add-on di Firefox per identità e password, abbandonato intorno al 2009. 🟡 *Xiippy*: startup australiana di pagamenti. 🟡 **`.xip`** è il formato di archivio firmato di Apple usato per Xcode: "Xipper" potrebbe far pensare a "uno strumento per i .xip". È un'ambiguità da tenere presente, anche se il formato non è un marchio. |
| Marchio | Nessuna registrazione emersa nelle ricerche. **Da fare:** ricerca formale su EUIPO, UIBM e USPTO in classe 9 |
| Domini | `xipper.com` registrato dal 2003 e rinnovato fino al 2035 (non disponibile) · `xipper.io` registrato nel 2024 · **`xipper.it` libero** · `xipper.app` da verificare con un registrar |
| Comando CLI `xipper` | 🟢 nessun conflitto noto con pacchetti Homebrew o di sistema |

**Valutazione:** "Xipper" è **molto più pulito di "Zipper"**. Si legge come "zipper" (la X iniziale si pronuncia Z in inglese, come in Xerox e Xylophone), quindi resta evocativo ma è distintivo e registrabile. I rischi residui sono il `.com` già occupato, il repo JayBrown/Xipper e l'associazione con `.xip`. → **Candidato raccomandato**, da confermare con la ricerca formale del marchio e con App Store Connect.

---

## 2. Panorama concorrenti su macOS

| App | Prezzo | Forza | Debolezza / spazio per noi |
|---|---|---|---|
| **Archive Utility** (di sistema) | gratis | integrato, zero attriti | solo zip/gz/bz2/cpio, nessuna password, nessuna UI |
| **The Unarchiver** | gratis | oltre 40 formati in lettura | sola estrazione, niente creazione o password |
| **Keka** | gratis (sito) / €5,99 (MAS) | creazione 7z/zip, AES-256, open source | UI essenziale; AES per ZIP disattivato di default; anteprime limitate |
| **BetterZip 5** | ~$25 | modifica dell'archivio in place, Quick Look, preset nella toolbar del Finder | costoso; per RAR e altri formati dipende da strumenti esterni |
| **Archiver 4** | ~$25 | UX curata, split e merge | a pagamento, chiuso |

**Possibili differenziatori di Zipper:**
1. **Prestazioni misurabili su Apple Silicon**: compressione multi-core vera anche per zip e gzip, CRC e AES in hardware. Benchmark pubblici contro Keka e BetterZip.
2. **Archivio montato come volume** (FSKit): si sfoglia, si apre e si copia dal Finder senza estrarre. Nessun concorrente lo offre in modo nativo.
3. **Integrazione completa con Comandi Rapidi** (App Intents): "comprimi con password", "verifica", "estrai in…" componibili in automazioni.
4. **Verifica come funzione di prima classe**: test di integrità, manifest SHA-256 e, in prospettiva, dati di recupero PAR2.
5. **Sicurezza di default**: protezione da zip-slip e zip-bomb, propagazione della quarantena, cifratura dei nomi file in 7z.

---

## 3. Vincolo "totalmente autoincluso": interpretazione

L'obiettivo si può leggere in tre modi.

| Livello | Significato | Pro | Contro |
|---|---|---|---|
| **A. Solo framework Apple + codice nostro** | Nessuna riga di codice di terzi | Massimo controllo, nessuna licenza da gestire | zstd, xz/LZMA2 in scrittura, PPMd, brotli in scrittura e il formato 7z vanno scritti **da zero**: mesi di lavoro e rischio di bug sui dati |
| **B. Framework Apple + codec open source permissivi compilati dentro** ⭐ | Nessuna dipendenza a runtime né installazione. Il sorgente di zstd/xz/LZMA SDK/libdeflate è *vendorizzato* nel repo e compilato staticamente | Codec maturi e testati su miliardi di file; ci concentriamo su container, UX e prestazioni | Bisogna gestire licenze e attribuzioni (BSD/MIT/0BSD/public domain, tutte compatibili con un'app commerciale chiusa) |
| C. Dipendenze esterne (Homebrew, `7z` di sistema, ecc.) | Fuori obiettivo | | ❌ escluso |

**Raccomandazione: livello B**, con questa regola:
- **I container** (ZIP, 7z, TAR, CPIO, AAR) li scriviamo **noi**, in Swift. È lì che stanno UX, parallelismo, sicurezza e gestione dei metadati macOS.
- **I codec** di base usano prima di tutto i **framework di sistema**. Il resto è **vendorizzato** solo da progetti con licenza permissiva. **Niente GPL/LGPL**: Xipper è open source con licenza **MIT** (§10), e tutto il codice incluso deve restare compatibile con MIT e con il link statico in un unico bundle (BSD, MIT, 0BSD, zlib, Apache-2.0).
- Il risultato resta *un solo bundle firmato* che non installa e non scarica nulla: è autoincluso nel senso che conta per l'utente.

> **Decisione presa il 21/10/2026: livello B.** I risultati dello spike sono in [SPIKE_FASE0.md](SPIKE_FASE0.md).

---

## 4. Formati

### 4.1 Cosa offre già macOS (zero codice di terzi)

| Componente | Cosa dà | Note |
|---|---|---|
| `Compression.framework` (libcompression) | deflate raw (zlib), **LZMA/xz** (codifica e decodifica), LZ4, LZFSE, LZBITMAP, **Brotli (solo decodifica)** | API a stream; ottimizzato da Apple per arm64 |
| `AppleArchive.framework` | formato `.aar` più compressione e cifratura (AEA) | Formato Apple, utile come formato "nativo" veloce, non open |
| `libz` / `libbz2` (in `/usr/lib`, nell'SDK) | zlib/gzip, bzip2 | Fanno parte del sistema operativo: non sono una dipendenza di terzi |
| `CryptoKit` / `CommonCrypto` | AES (CBC/CTR/GCM), HMAC-SHA1/256, PBKDF2, SHA-1/256/512 | Usano le istruzioni AES/SHA di ARMv8 |
| `Security.framework` | Keychain, accesso con Touch ID | Per salvare le password degli archivi |
| `libarchive` | presente nel sistema operativo, ma **headers non pubblici nell'SDK** | Linkarla è fragile e a rischio di rifiuto: **da non usare** |

### 4.2 Matrice formati proposta

Legenda: ✅ v1 · 🔜 v2 · 📖 solo lettura · ❌ no

| Formato | Crea | Estrae | Password | Codec / origine |
|---|---|---|---|---|
| **ZIP** (deflate) | ✅ | ✅ | ✅ AES-256 (WinZip AE-1/AE-2) · ZipCrypto solo su richiesta, con avviso (UI 2.7) | deflate: libdeflate (MIT) per la compressione veloce, zlib di sistema come fallback |
| ZIP con **zstd (metodo 93)** | ✅ v1 | ✅ | ✅ AES-256 | zstd (BSD); leggibile da 7-Zip ≥ 21, WinZip, libarchive (non da Utility Archivio). Nell'app: «ZIP · zstd» nel menu Formato |
| ZIP: bzip2, LZMA (14), xz (95) | ❌ | ✅ | — | lettura per compatibilità |
| ZIP: deflate64 | ❌ | 🔜 | — | da implementare |
| ZIP64 (oltre 4 GB / 65.535 voci) | ✅ | ✅ | | nostro |
| ZIP multi-volume (`.z01`…, `.zip.001`…) | 🔜 | ✅ fatto | | nostro (lettura di parti unite, da qualsiasi parte) |
| **7z** | ✅ fase 3 | ✅ | ✅ AES-256 + **cifratura dei nomi file** (default con password) | contenitore nostro; LZMA/LZMA2 da liblzma (LZMA2 multi-thread in scrittura, decodifica parallela ai reset), PPMd dal LZMA SDK (pubblico dominio, solo lettura), BCJ/BCJ2/ARM64/ARM/ARMT/PPC/SPARC/RISC-V/Delta, BZip2, Deflate; solid configurabile, multi-volume in lettura e scrittura → [FASE1.md](FASE1.md) |
| **TAR** (ustar, pax, GNU) | ✅ | ✅ | — | nostro |
| **tar.gz / .tgz**, **gzip** | ✅ | ✅ | | deflate parallelo (stile pigz) |
| **tar.bz2**, **bzip2** | ✅ | ✅ | | libbz2 di sistema, parallelo per blocchi |
| **tar.xz**, **xz** | ✅ | ✅ | | xz-embedded/liblzma (0BSD), xz multi-blocco parallelo |
| **tar.zst**, **zstd** | ✅ | ✅ | | zstd (BSD), multithread nativo |
| lz4, brotli (anche `tar.lz4`, `tar.br`) | 🔜 | ✅ fatto | | lz4: decoder del formato frame scritto da noi (blocchi indipendenti e collegati, xxHash32); brotli: Compression di sistema |
| CPIO (newc, crc, odc), `.aar` (Apple Archive) | ✅ fatto | ✅ fatto | ✅ AEA (password di almeno 20 caratteri, limite di macOS) | cpio nostro (scrittura newc); Apple Archive tramite il framework AppleArchive di sistema (LZ4/LZFSE/LZMA, attributi estesi), con l'estrazione sicura di Xipper |
| ISO 9660 / UDF | ❌ | 🔜 📖 | | nostro (lettura semplice) |
| **RAR / RAR5** | ❌ (vietato dalla licenza RAR) | ✅ solo lettura, v2 | ✅ AES di RAR5 (RAR3 da valutare) | clean-room, vedi sotto |
| DMG | ❌ | ❌ | | si gestisce con `hdiutil`; non è un formato di archivio aperto |
| **BGZF / bgzip** (`.gz`, `.bgz`, `.vcf.gz`, `.bed.gz`, `.fa.gz`; contenitore di BAM/BCF) | ✅ fase 1.6 | ✅ parallela | — | nostro, su libdeflate; vedi §4.4 |
| **MPEG-G** (ISO/IEC 23092, `.mgb`) | ⚠️ | ⚠️ | — | brevetti e licenze da chiarire prima di qualsiasi implementazione; vedi §4.5 |

**Caso RAR, decisione del 21/10/2026: sola lettura, clean-room.** RAR è proprietario. La licenza di `unrar` permette di estrarre, ma vieta di usarne il codice per ricostruire il compressore e non è compatibile con MIT, quindi **non usiamo né guardiamo il sorgente di unrar**.
- **Fonti ammesse:**
  - la documentazione pubblica del formato contenitore RAR5 (technote di RARLAB);
  - implementazioni indipendenti con licenza permissiva, in particolare i lettori RAR e RAR5 di **libarchive** (BSD-2), che Apple stessa distribuisce in macOS dentro `bsdtar`.
- **Percorso consigliato:** partire da un port o vendoring dei lettori RAR/RAR5 di libarchive (BSD-2, compatibile con MIT), avvolto dall'estrazione sicura di Xipper (§7) e dalla decompressione in streaming. Un decoder riscritto da zero sulla stessa documentazione è l'alternativa più pulita ma più costosa (stima 4–6 settimane in più).
- **Ambito:**
  - RAR5 e RAR 2.9/3.x;
  - archivi multi-volume (`.part1.rar`…, `.r00`…);
  - verifica tramite CRC32 e BLAKE2sp (RAR5);
  - archivi cifrati RAR5 (AES-256-CBC, chiave PBKDF2-HMAC-SHA256, tutto disponibile in CommonCrypto) e intestazioni cifrate;
  - da valutare a parte: RAR3 cifrato (AES-128 con KDF SHA-1 proprietaria) e archivi "solid" molto grandi (decodifica necessariamente sequenziale).
- **Fuori ambito:** creazione di RAR, recovery record, archivi SFX Windows (si possono estrarre se il contenitore è standard).
- **Nota legale:** sui formati RAR non risultano brevetti attivi; il nome "RAR" è un marchio di RARLAB e va usato solo in modo descrittivo ("apre archivi RAR"). La conferma di un legale resta raccomandata prima del rilascio.

### 4.3 Requisiti trasversali sui formati
- **Nomi file:** UTF-8 con il flag bit 11 in ZIP; normalizzazione NFD↔NFC (APFS conserva la forma, Windows usa NFC); in lettura si rileva la codepage legacy (CP437, CP866, Shift-JIS…).
- **Metadati macOS:** xattr, ACL, flag BSD, date di creazione, permessi, symlink. In ZIP si scrive opzionalmente il formato AppleDouble `__MACOSX/` *solo* se l'utente lo chiede; di default si producono ZIP "puliti" per Windows.
- **Esclusioni automatiche configurabili:** `.DS_Store`, `._*`, `.Spotlight-V100`, `.git`, `node_modules`.

---

### 4.4 BGZF (bgzip), il gzip della genomica

**Cos'è.** BGZF ("Blocked GNU Zip Format", SAM/BAM spec v1 §4.1) è una serie di membri gzip **indipendenti**, ciascuno di al massimo 64 KiB prima e dopo la compressione. Ogni membro porta nell'header un extra field `BC`:
- `FLG.FEXTRA` = 1;
- subfield `SI1`=66, `SI2`=67, `SLEN`=2;
- `BSIZE` = dimensione totale del blocco − 1 (uint16 LE).

Il file termina con un blocco vuoto di 28 byte che segnala la fine (EOF marker):
`1f 8b 08 04 00 00 00 00 00 ff 06 00 42 43 02 00 1b 00 03 00 00 00 00 00 00 00 00 00`

È compatibile con `gunzip`, ma permette l'accesso casuale: gli indici `.tbi`/`.csi` (tabix) e `.bai` (BAM) usano *virtual offset* `coffset<<16 | uoffset`. bgzip può produrre anche un indice `.gzi`: uint64 LE con il numero di voci, seguito da coppie (offset compresso, offset non compresso). È il formato standard per VCF, BED, GFF, FASTA e FASTQ compressi, e il contenitore di BAM e BCF.

**Perché conta.** In genomica un `.vcf.gz` compresso con gzip "normale" non si può indicizzare né interrogare per regione: gli strumenti (bcftools, tabix, IGV) pretendono BGZF. Oggi l'utente Mac deve installare htslib da Homebrew o conda solo per questo.

**Cosa farà Xipper:**

| Funzione | Dettaglio |
|---|---|
| **Riconoscimento** | Dall'header gzip con extra field `BC`, non solo dall'estensione. Il formato viene mostrato come "BGZF" nell'inspector e in Quick Look. |
| **Compressione BGZF** | Blocchi da 0xFF00 byte (come htslib), così il blocco compresso sta sempre in 64 KiB; se un blocco non si comprime, viene salvato come blocco deflate *stored*. I blocchi sono indipendenti, quindi il parallelismo è perfetto su tutti i P-core con libdeflate (la stessa libreria che usa htslib). Il marker EOF è sempre scritto. Livelli 0–9 compatibili con `bgzip -l`. |
| **Decompressione parallela** | Una scansione sequenziale degli header (`BSIZE` dà subito l'offset del blocco seguente) e poi la decompressione dei blocchi in parallelo, con dimensione d'uscita nota (`ISIZE`) e CRC per blocco. Oggi `gunzip` è a thread singolo. |
| **Verifica** | CRC di ogni blocco più la presenza del marker EOF: rileva i file troncati, il problema più frequente sui trasferimenti di BAM e VCF. Funziona anche su **BAM e BCF**, senza bisogno di interpretarne il contenuto. |
| **Conversione gzip → BGZF** | L'azione rapida "Converti in BGZF" ricomprime in streaming un `.vcf.gz` creato con gzip normale. Va anche nel senso inverso. |
| **Indice `.gzi`** | Creato a richiesta, compatibile con `bgzip -i`/`-I`. Gli indici `.tbi`/`.csi`/`.bai` esistenti non vengono mai toccati. Se un file viene ricompresso, Xipper avvisa che il suo indice tabix non è più valido (la creazione di indici tabix richiede di interpretare VCF/BED/GFF ed è prevista in v2). |
| **Preferenza "Genomica"** | Quando si comprime in `.gz` un file `.vcf`, `.bed`, `.gff`/`.gtf`, `.fa`/`.fasta`, `.fq`/`.fastq` o `.sam`, Xipper usa BGZF di default (attivo di default, disattivabile). |
| **Smart store** | Nelle creazioni ZIP/tar, `.bam`, `.cram`, `.bcf`, `.bgz`, `.vcf.gz`, `.fastq.gz`, `.sra` e gli indici (`.bai`, `.crai`, `.tbi`, `.csi`) vengono salvati senza ricomprimerli. |

**Integrazione:** azioni nel Finder ("Comprimi con BGZF", "Converti in BGZF", "Verifica BGZF/BAM"), un'azione in Comandi Rapidi, i tool MCP `bgzf_compress`, `bgzf_check`, `bgzf_convert`, e il comando CLI `xipper bgzip`, compatibile con le opzioni principali di `bgzip` (`-c`, `-d`, `-i`, `-l`, `-@`).

**Licenze:** nessun problema. BGZF è una specifica aperta (hts-specs) senza brevetti noti, e l'implementazione è nostra, sopra libdeflate (MIT).

**Test:**
- interoperabilità con htslib (`bgzip`, `tabix`, `samtools quickcheck`), installato via Homebrew solo in CI;
- confronto byte per byte del contenuto decompresso;
- validità degli indici `.gzi`;
- file troncati senza marker EOF.

### 4.5 MPEG-G (ISO/IEC 23092)

**Cos'è.** Uno standard ISO/IEC (prima edizione 2019) in sei parti:
1. trasporto e archiviazione;
2. codifica;
3. metadati e API;
4. software di riferimento;
5. conformità;
6. annotazioni.

Non comprime byte generici: **transcodifica** le letture FASTQ e gli allineamenti SAM/BAM in "record MPEG-G" (`.mgrec`) e li codifica con codec specifici per tipo di dato, cioè CABAC/GABAC e, per la qualità, CALQ con perdita. L'output è `.mgb` (eventualmente in un contenitore Part 1). La modalità con riferimento richiede il FASTA del genoma.

**Stato dell'arte (ottobre 2026):**
- **Implementazione open source: [Genie](https://github.com/tnt-LUH/genie)** (Leibniz Universität Hannover e UIUC; ex `MueFab/genie`, prima ancora `mitogen/genie`).
  - Licenza BSD-3, C++17, circa 89.000 righe proprie, basata su SPRING e GABAC.
  - Articolo: Müntefering et al., *Genie: the first open-source ISO/IEC encoder for genomic data*, Communications Biology 7:553 (9/5/2024).
  - **Cosa implementa:**
    - Part 2, con quattro modalità: global assembly (SPRING), low latency, local assembly e con riferimento;
    - CABAC dello standard e GABAC, più zstd, lzma e bsc che sono fuori standard;
    - Part 1, file `.mgg` tramite `capsulator`.
  - **Cosa manca:**
    - la Part 3, cioè l'API C: le 13 funzioni dell'header restituiscono solo un errore;
    - la Part 6 esiste solo sul ramo `develop-part6`, con la CI che fallisce (ultimo commit 25/9/2026).
  - **È un sottoinsieme dello standard:**
    - mancano gli half-aligned, gli allineamenti secondari e supplementari e i tag opzionali, che nei benchmark sono stati filtrati;
    - in global assembly le letture sono limitate a 511 basi;
    - il SAM decompresso non torna nell'ordine originale (issue #11).
  - **Maturità:**
    - sul ramo principale l'ultimo commit è del 14/5/2025 e la v2.0 è solo una pre-release;
    - 50 stelle, issue aperte ferme al 2020–2022;
    - CI solo su Linux, macOS non testato.
  - **Integrazione:**
    - dipende da htslib, zlib, bzip2, liblzma, zstd e libbsc; libbsc va compilata a mano;
    - su Apple CMake disattiva OpenMP, quindi su macOS gira a un solo thread;
    - c'è solo un'API C++ dentro la CLI: in pratica si potrebbe solo includere il binario.
- **Prestazioni riportate:**
  - FASTQ: rapporto mediano sotto 0,15 rispetto a gzip, ma codifica circa 7 volte più lenta di gzip;
  - dati allineati: leggermente meglio di CRAM, ma 3–4 volte più lento di DeeZ; oltre l'80% del tempo va in CABAC, che lavora bit per bit;
  - in entrambi i casi Genozip fa meglio;
  - un articolo del 2026 stima circa 4,3× di compressione in più rispetto ai compressori generici e circa 5× di prestazioni in meno.
- **Brevetti e licenze: è il punto critico.**
  - Philips nel 2021 ha concesso a **GenomSys una licenza esclusiva** sui propri brevetti MPEG-G.
  - GenomSys ha una famiglia di circa 12 domande PCT del 2016, tra cui:
    - EP3526711B1, concesso nel 2023, scadenza attesa nel 2036;
    - US11404143 (indicizzazione), US11386979 (archiviazione e accesso), US11763918 (unità di accesso).
  - **Novità (analisi del 21/10/2026):** secondo Google Patents, US11404143 e US11386979 risultano **assegnati da GenomSys a Philips** (novembre 2025). Non ci sono comunicati: da verificare.
  - Gli autori di Genie (Voges, Ostermann) dichiarano nei "competing interests" dell'articolo di essere inventori di brevetti (EP3311318B1, EP3652862B1, US10938415B2, CN110915140B) implementati in parte nel software.
    - Il file `LICENSE` di Genie si apre con un preambolo: il software "may be subject to other third party and contributor rights, including patent rights, and no such rights are granted under this license".
    - Usare o ridistribuire Genie copre quindi solo il diritto d'autore.
  - Non esistono patent pool, FRAND né royalty pubblici.
    - La FAQ ufficiale di MPEG-G dice: "there is currently no royalty rate in place".
    - Non c'è nessuna esenzione per l'open source.
    - Una licenza gratuita di GenomSys per la ricerca compariva solo in estratti di ricerca, non verificata; in ogni caso riguarda solo i brevetti GenomSys.
  - Non risultano cause né opposizioni all'EPO. J. Bonfield (CRAM/htslib) contesta i brevetti per anteriorità (samcomp, Crumble, CRAM).
  - **Rischio per Xipper (deduzione, non parere legale):**
    - un encoder è più esposto, perché le rivendicazioni riguardano la rappresentazione e la codifica;
    - un decoder lo è meno, ma non è al sicuro: ci sono rivendicazioni su accesso e indicizzazione;
    - l'Europa non è un riparo: l'EPO concede queste invenzioni implementate al calcolatore e il Tribunale unificato dei brevetti, dal 2023, le fa valere in molti Stati insieme;
    - l'esposizione dura fino al 2036–2038.
  - Il testo dello standard è a pagamento (ISO).
  - Parte della comunità bioinformatica è critica, e preferisce gli standard GA4GH (CRAM, VCF).
- **Diffusione:** limitata. Ci sono attività commerciali di GenomSys, ma nei risultati delle ricerche nessuna delle grandi piattaforme genomiche annuncia supporto nel 2025–2026.

**Valutazione per Xipper.**
1. **Il vincolo "formati open" non è soddisfatto finché i brevetti non sono chiariti.** Distribuire un encoder o decoder MPEG-G in un'app commerciale senza licenza è un rischio legale concreto, anche usando Genie.
2. **Non è un formato d'archivio.** La transcodifica non restituisce il file originale byte per byte: si ottengono FASTQ/SAM equivalenti, con possibili perdite (qualità, tag, record non supportati). In un archiviatore, dove "estrai" deve ridare esattamente i file originali, va presentata come **esportazione/importazione genomica**, separata dalla compressione.
3. **Autoinclusione:** Genie è C++ con le sue dipendenze (SPRING, GABAC e altre di terze parti) e andrebbe vendorizzato. Si può fare (BSD-3), ma aumenta molto superficie e manutenzione.

**Piano proposto a fasi, con un passaggio legale vincolante:**

| Passo | Contenuto | Condizione |
|---|---|---|
| **G0. Verifica legale** | Contatto con GenomSys e con i titolari dei brevetti (Philips, ora anche per parte della famiglia GenomSys negli USA, e LUH) per una licenza scritta; parere di un avvocato brevettuale; acquisto delle parti 1–3 della ISO/IEC 23092 | **prima di scrivere codice MPEG-G** |
| **G1. Riconoscimento** | Riconoscere i file `.mgb` e i contenitori MPEG-G, con icona, Quick Look delle informazioni di base (dimensione e, se il contenitore lo espone, numero di record e riferimento) e nessuna decodifica | solo parsing dell'header, rischio basso; da confermare con G0 |
| **G2. Decodifica** | `.mgb` → FASTQ/SAM (con BGZF/BAM in uscita), un modulo basato su Genie vendorizzato, con un report delle eventuali perdite | licenza ottenuta |
| **G3. Codifica** | FASTQ/BAM → `.mgb` come "Esporta in MPEG-G", con scelta della modalità (global assembly, low latency, con riferimento) e avviso sulla qualità con perdita | licenza ottenuta, domanda reale dagli utenti |

> **Opzione preferita: CRAM.** Per la compressione specifica di dati genomici l'alternativa aperta e molto più diffusa è **CRAM 3.1** (GA4GH, implementazione htslib con licenza MIT/BSD), insieme a BGZF per VCF/BED/FASTQ, che Xipper gestisce già.
> - Per gli allineamenti la compressione è più o meno pari a quella di Genie con riferimento.
> - È molto più veloce e senza nodi brevettuali noti.
> - Xipper ne verifica già la struttura (fase 1.7).
>
> Analisi del 21/10/2026: finché G0 non dà esito positivo, per MPEG-G si fa al massimo il passo G1 (riconoscimento), e la scrittura e lettura di CRAM diventa la candidata per la genomica compressa nella v2.

### 4.6 Standard GA4GH (analisi del 21/10/2026)

GA4GH cura i formati di file della genomica (hts-specs: SAM/BAM, CRAM, VCF/BCF, indici) e diverse API per i dati in rete. Per un archiviatore contano i **formati e gli indici**, i **checksum** e, come client, **DRS** e **htsget**. Le API di federazione non riguardano i file.

| Standard | Stato | Cosa può fare Xipper | Priorità |
|---|---|---|---|
| **tabix (.tbi) e CSI** | hts-specs | Creare l'indice di VCF/BED/GFF ordinati e compressi BGZF: "bgzip + tabix" in un solo gesto, nel Finder, nella CLI e via MCP | **Alta** |
| **Coerenza degli indici** (.tbi/.csi/.bai/.gzi) | hts-specs | Verificare che i virtual offset cadano su confini BGZF validi e che l'indice non sia più vecchio del file (estende la §4.4) | **Alta** |
| **CRAM 3.0/3.1**, verifica strutturale | CRAM 3.0 approvato; il testo 3.1 aggiunge 4 codec | Controllare i CRC32 di container e blocchi e il container EOF **senza decodificare** | **Alta** |
| **VCF 4.5 / BCF**, verifica | hts-specs | VCF.gz: BGZF valido più l'header `##fileformat`; BCF: BGZF più il magic | **Alta** |
| **Checksum** (convenzioni DRS/IANA) | DRS `checksums` | Generare e verificare manifest sha-256 / md5 / crc32c con nomi compatibili DRS/IANA (anche `sha256` senza trattino); sha512t24u opzionale | **Alta** |
| **DRS 1.4/1.5**, client | approvato (Apache-2.0) | `drs://host/id` → access URL → download → verifica del checksum → estrazione o verifica BGZF | Media |
| **htsget 1.3**, client | approvato | Scaricare una regione `chr:start-end` di BAM/CRAM/VCF in un file locale verificato (con indice) | Media |
| **BAI/CSI per BAM** | hts-specs | Indicizzare BAM: richiede il parsing dei record e il calcolo dei bin | Media |
| **RO-Crate (+ BagIt)** | *non GA4GH* (ResearchObject/ELIXIR) | Esportare uno zip RO-Crate con manifest, per pubblicazione e workflow | Media |
| **CRAM 3.1**, decodifica | htscodecs BSD, htslib MIT | Container, slice, rANS Nx16, arithmetic coder, fqzcomp, tokenizer dei nomi, più il riferimento via refget | Bassa |
| **refget v2** | approvato 2023 | Recuperare sequenze di riferimento per MD5 (`@SQ M5`); serve solo per decodificare CRAM | Bassa |
| **CRAM 3.1**, codifica; **CRAI** | — | Porting di htscodecs: un progetto a sé | Bassa |
| Data Connect, Beacon v2, Phenopackets, TES/WES, Passports | approvati | Non riguardano file né compressione (al massimo un bearer token per DRS/htsget) | Esclusi |
| Crypt4GH | — | — | **Escluso** (decisione del 21/10/2026) |

**Vincoli:**
- I client DRS e htsget introducono **accesso di rete**. Oggi Xipper non si collega mai a Internet (vedi le note della beta), quindi servono un opt-in esplicito, un token fornito dall'utente e la registrazione nel log di audit.
- Licenze: htslib MIT/BSD e htscodecs BSD/pubblico dominio sono compatibili con MIT, mantenendo gli avvisi. Il testo delle specifiche hts-specs non ha una licenza dichiarata, ma l'implementazione da specifica non pone problemi pratici.
- **Da confermare:** l'approvazione formale di CRAM 3.1 e VCF 4.5 sulle pagine GA4GH, e la data di DRS 1.4 (sito e GitHub non coincidono).

**Piano proposto:**
- **Fase 1.7 "Genomica 2"** ✅ (completata il 21/10/2026, vedi [FASE1.md](FASE1.md); resta l'integrazione con il Finder, che arriva con l'app) (circa 2 settimane, solo locale): creazione di tabix/CSI, verifica degli indici, verifica strutturale di CRAM e VCF/BCF, manifest dei checksum. Arriva su CLI (`xipper tabix`, `xipper manifest`), Finder e MCP (`genomics_index`, `genomics_check`, `checksum_manifest`).
- **Fase 2.x "Genomica in rete"** (opt-in): client DRS e htsget.
- **Più avanti, su richiesta:** decodifica CRAM con refget.

> Fonti: ga4gh.org (pagine prodotto SAM/BAM, CRAM, refget, htsget, DRS); github.com/samtools/hts-specs (CRAMv3.tex, CRAMcodecs.tex, htsget.md, refget.md); github.com/ga4gh/data-repository-service-schemas (release 1.4.0 e 1.5.0, Checksum.yaml); htslib e htscodecs (LICENSE); researchobject.org (RO-Crate 1.3).

## 5. Ottimizzazioni Apple Silicon (arm64)

### 5.1 CPU e parallelismo
- **Topologia P/E:** lavoro pesante a QoS `.userInitiated` (P-core); compressioni in background, come le Azioni rapide o le cartelle sorvegliate, a `.utility` (E-core, meno consumo e meno calore). Thread contati con `sysctl hw.perflevel0.physicalcpu` / `hw.perflevel1.physicalcpu`.
- **Parallelismo per formato**, dove la maggior parte dei concorrenti è a un solo thread:
  - **ZIP:** ogni voce è indipendente, quindi si comprimono N file in parallelo. Un file grande si divide in blocchi deflate con un dizionario innescato (tecnica pigz) e un CRC combinato (`crc32_combine`).
  - **gzip:** pigz-like, flusso compatibile al 100%.
  - **xz:** formato multi-blocco, compressione e *decompressione* parallele.
  - **zstd:** multithread nativo (`ZSTD_c_nbWorkers`), più la modalità `--long` per archivi grandi.
  - **7z:** LZMA2 multi-blocco più "solid block" configurabile.
  - **bzip2:** blocchi da 900 KB indipendenti, quindi parallelismo naturale.
- **Pipeline** lettura → compressione → cifratura → scrittura, con ring buffer e back-pressure: niente picchi di RAM con archivi da centinaia di GB.

### 5.2 Istruzioni hardware ARMv8
| Operazione | Accelerazione | Guadagno atteso |
|---|---|---|
| CRC32 (ZIP, gzip) | istruzioni `CRC32X` + folding con `PMULL` (NEON) | oltre 20 GB/s contro ~1 GB/s per la versione a tabella |
| CRC32C, xxHash64 (zstd) | `CRC32CX`, NEON | |
| Adler-32 (zlib) | NEON | |
| AES-256 (ZIP AES-CTR, 7z AES-CBC) | estensioni crittografiche ARMv8 tramite CommonCrypto | multi-GB/s, la cifratura smette di essere un collo di bottiglia |
| SHA-1 (HMAC per ZIP AES), SHA-256 (KDF 7z, manifest) | `SHA1*`/`SHA256*` tramite CryptoKit | |
| PBKDF2 (ZIP AES: 1000 iterazioni) | CommonCrypto | |
| match finder LZ, memcpy | NEON a 128 bit, già ottimizzato in zstd/libdeflate | |

### 5.3 Memoria e I/O
- **Memoria unificata, pagine da 16 KB:** buffer allineati a 16 KB, `mmap` per la lettura sequenziale degli archivi, `madvise(MADV_SEQUENTIAL)`.
- **`F_NOCACHE`** per file enormi, così non si svuota la cache del sistema.
- **APFS:**
  - `clonefile()` quando si "estrae" una voce memorizzata (metodo *store*) da un archivio sullo stesso volume. È una copia istantanea, in alcuni casi.
  - Allocazione anticipata con `fcntl(F_PREALLOCATE)` per l'archivio in uscita.
  - Scrittura atomica: file temporaneo e poi `rename`, così un'interruzione non lascia archivi corrotti.
- **SSD:** I/O concorrente con `DispatchIO`, coda profonda.
- **Metal/GPU:** non è utile per i codec LZ, che sono sequenziali e pieni di diramazioni. **Regola del 21/10/2026:** assembler ARM64/NEON e GPU vanno usati dove un benchmark mostra un guadagno, con un percorso portabile di riserva e test che confrontano i due. Candidati da misurare: decodifica parallela per blocchi (BGZF, xz multi-blocco) e impronte di molti file piccoli; CRC32 usa già le istruzioni `CRC32X`/`PMULL` tramite libdeflate.

### 5.4 Obiettivi di prestazione (da validare con benchmark)
- tar.zst livello 3 su M-series: velocità limitata dall'SSD (oltre 3 GB/s).
- ZIP deflate livello 6: almeno 4× Archive Utility e almeno 2× Keka, su un mix reale di file.
- Estrazione ZIP AES-256: entro il 10% della stessa estrazione senza cifratura.
- Suite di benchmark ripetibile (Silesia corpus, un repo di codice, una cartella di foto, un file singolo da 10 GB) inclusa nel progetto fin dall'inizio.

---

## 6. Integrazione con macOS

| Estensione / API | Cosa fa per l'utente | Note tecniche |
|---|---|---|
| **Associazione dei tipi documento (UTI)** | doppio clic su `.zip`, `.7z`, `.tar.xz`… apre Zipper | `CFBundleDocumentTypes` e `UTImportedTypeDeclarations`; impostabile come app predefinita |
| **Finder Sync Extension** | menu contestuale "Comprimi ▸ preset", "Estrai qui", "Estrai in…", "Verifica"; pulsante nella toolbar del Finder | API `FIFinderSync`; funziona in sandbox |
| **Azioni rapide / Servizi** | voce nel pannello Anteprima del Finder e in *Servizi* | Action Extension e `NSServices` |
| **App Intents → Comandi Rapidi** ⭐ | azioni "Comprimi file", "Estrai archivio", "Verifica archivio", "Elenca contenuto", "Aggiungi password" componibili; disponibili anche in Spotlight, Siri e come Azione rapida | App Intents è l'erede moderno di Automator ed è il punto che chiedevi per le "azioni di macOS" |
| **Quick Look Preview Extension** | spazio su un `.zip` mostra l'albero dei file con dimensioni e rapporto di compressione, e l'anteprima del singolo file interno | `QLPreviewingController`; sola lettura e streaming |
| **Thumbnail Extension** | icona dell'archivio con il numero di file e il formato | `QLThumbnailProvider` |
| **FSKit (macOS 15.4+)** ⭐ | **monta l'archivio come volume** in sola lettura: lo si sfoglia nel Finder e le app aprono i file senza estrarre | il differenziatore principale; prima un MVP in sola lettura per ZIP e TAR |
| **Spotlight** | ricerca per nome dei file *dentro* gli archivi | importer di metadati (da valutare per costo e beneficio) |
| **CLI `zipper`** inclusa nel bundle | uso da terminale e script; installazione opzionale di un symlink in `/usr/local/bin` | stesso core dell'app; serve un nome diverso da `zipper`, già usato da unxed/zipper |
| **Cartelle sorvegliate** | ogni file messo in "Da comprimere" viene archiviato | `FSEvents`; si lancia come agente con `SMAppService` |
| **Keychain e Touch ID** | memorizza le password degli archivi, per archivio o per profilo | `kSecAttrAccessControl` con `.biometryCurrentSet` |
| **Notifiche e Dock** | avanzamento nell'icona del Dock e notifica a fine lavoro | |

---

## 6-bis. Interfaccia: studio secondo Liquid Glass

Liquid Glass è il linguaggio visivo introdotto con macOS 26 e rifinito in macOS 27, soprattutto per la leggibilità. Le API sono state verificate nell'SDK di Xcode 27 installato: `glassEffect(_:in:)`, `Glass.regular/.clear/.identity` con `.tint()` e `.interactive()`, `GlassEffectContainer`, `glassEffectID` e `glassEffectUnion`, `.buttonStyle(.glass)` e `.glassProminent`, `ToolbarSpacer`, `ConcentricRectangle`, `backgroundExtensionEffect()`, `scrollEdgeEffectStyle`. Nessuna di queste è nuova in macOS 27.
→ **Il target minimo sale a macOS 26**, dove Liquid Glass è nativo, invece del 15 indicato nel §8.

### Principi applicati a Xipper
1. **Il vetro serve alla navigazione, non al contenuto.** Toolbar, sidebar, barre d'azione e HUD di avanzamento galleggiano in vetro. La lista dei file dell'archivio (il contenuto) resta una `Table` standard e opaca.
2. **Mai vetro su vetro.** Niente card in vetro dentro una sidebar di vetro. Gli elementi in vetro vicini stanno in un unico `GlassEffectContainer`, così si fondono e si trasformano in modo coerente.
3. **Prima i componenti di sistema.** `NavigationSplitView` (la sidebar flottante è automatica), `.toolbar` con gruppi separati da `ToolbarSpacer`, `.inspector`, `.sheet`, `Form` nelle impostazioni. Il vetro personalizzato si usa solo dove serve davvero: la zona di rilascio e l'HUD dei lavori.
4. **Colore solo per l'azione primaria:** una sola azione `.glassProminent` per vista, cioè "Comprimi" o "Estrai". Il resto usa `.glass` neutro. La tinta del vetro ha valore semantico (per esempio rosso per un errore di verifica), non decorativo.
5. **Forme concentriche:** angoli che seguono il raggio della finestra (`ConcentricRectangle` e `containerShape`). Niente raggi scelti a mano.
6. **Bordi di scorrimento:** la `Table` sotto la toolbar usa `scrollEdgeEffectStyle(.hard, for: .top)`, perché le intestazioni di colonna sono fisse e la vista è densa.
7. **Accessibilità obbligatoria:** con Riduci trasparenza si passa a `Glass.identity` per il vetro personalizzato; con Riduci movimento niente animazioni di morphing; con Aumenta contrasto si usano bordi. I componenti di sistema si adattano da soli.
8. **Icona dell'app** creata con **Icon Composer** (formato `.icon` a livelli), con le varianti chiaro, scuro, tinta e trasparente.

### Schermate

| Schermata | Struttura | Liquid Glass |
|---|---|---|
| **Home / Drop** (nessun documento aperto) | Ampia zona di rilascio e, in basso, una barra d'azione flottante: formato ▾ · livello ▾ · 🔒 password · **Comprimi** | La barra è una capsula `glassEffect` dentro un `GlassEffectContainer`. Al rilascio dei file la zona *si trasforma* nella barra d'avanzamento (`glassEffectID`). |
| **Browser archivio** | `NavigationSplitView`: sidebar con Recenti, Preferiti e Preset; `Table` al centro (nome, dimensione, compresso, rapporto, data, 🔒); `.inspector` con dettagli, checksum e verifica; percorso in alto per le sottocartelle | Sidebar e toolbar di sistema. Toolbar a gruppi: [Estrai (prominent)] · [Aggiungi, Elimina] · [Verifica] · ricerca |
| **Lavori in corso** | HUD flottante: MB/s, tempo stimato, file corrente, annulla. Avanzamento anche nell'icona del Dock | Una capsula di vetro che si espande in pannello (`glassEffectID`); più lavori diventano una pila di capsule unite (`glassEffectUnion`) |
| **Password** | `.sheet`: SecureField, indicatore di robustezza, "Cifra anche i nomi dei file" (7z), "Salva nel Portachiavi (Touch ID)" | Sheet di sistema, già in vetro |
| **Esito verifica** | Elenco delle voci con stato ✓ / ✗ ed errori evidenziati | Il vetro è tinto (rosso) solo nel banner di riepilogo in caso di errori |
| **Impostazioni** | `Settings` con `Form(.grouped)`: Generali, Formati, Sicurezza, Integrazioni (Finder, Comandi Rapidi), Prestazioni (P-core/E-core) | Solo componenti standard |
| **Menu bar extra** (opzionale) | Lavori attivi e cartelle sorvegliate | Popover di sistema |

Quick Look ed estensioni del Finder usano l'interfaccia del sistema: niente vetro personalizzato.

> Fonti: SDK SwiftUI di Xcode 27 (verifica diretta); guide di terze parti su `GlassEffectContainer` e sull'accessibilità; resoconti sui ritocchi di Liquid Glass in macOS 27 (WWDC26). Prima del design definitivo vanno lette le HIG Apple aggiornate e le sessioni WWDC26.

**Design dei flussi (40 tavole, prototipo navigabile, chiaro/scuro, Riduci trasparenza, Aumenta contrasto, Riduci movimento, icona):** [Xipper — Flussi Liquid Glass](https://claude.ai/artifact/CspdHhiqFhGPGUY36aTxjs)

---

## 6-ter. Interfaccia MCP (agenti AI)

Obiettivo: permettere ad agenti come Claude Desktop, Claude Code e altri client MCP di elencare, verificare, estrarre e creare archivi con Xipper, mantenendo il vincolo di autoinclusione e le garanzie di sicurezza.

### Stato dell'arte (ottobre 2026)
- **Specifica MCP corrente: 2026-07-28**, la versione "stateless". Spariscono `initialize` e le sessioni ed entra `server/discover`. Le richieste che il server faceva al client (elicitation, roots) diventano *Multi Round-Trip Requests* con `resultType: "input_required"`. Roots, Sampling e Logging sono deprecati. Molti client installati parlano ancora la **2025-11-25** → **il server deve supportare entrambe le versioni** (il client sonda con `server/discover` e, se riceve un errore, ripiega su `initialize`).
- **Trasporto:** solo **stdio** (JSON-RPC 2.0, un messaggio per riga; stdout riservato al protocollo, log su stderr). Streamable HTTP non serve a un'app desktop locale.
- **SDK Swift ufficiale** (`modelcontextprotocol/swift-sdk`): dipende da swift-system, swift-log ed eventsource, e in risoluzione anche swift-nio; inoltre risulta fermo alla 2025-11-25. → **Non lo usiamo** perché violerebbe l'autoinclusione. Scriviamo un server nostro: circa 1.000–1.800 righe, solo Foundation. L'SDK resta utile come client nei test di CI, senza essere distribuito.
- **Apple:** nelle beta di macOS 26.1 c'erano tracce di MCP legato agli App Intents, ma non è mai arrivato in una release. Al WWDC26 MCP è stato annunciato solo in Xcode 27 (`xcrun mcpbridge`). **Non c'è un ponte di sistema App Intents → MCP.** → Due adapter sottili sopra lo stesso core: App Intents (Siri, Comandi Rapidi, Spotlight) e MCP (agenti terzi), con nomi e schemi allineati per essere pronti se Apple aprirà il ponte.

### Architettura
```
XipperKit (core)  ──►  ArchiveService (API unica, sincrona, cancellabile, con progress)
                          ├─ App Intents adapter   (Xipper.app)
                          ├─ CLI                    (xipper …)
                          └─ MCP adapter            (xipper mcp  → stdio JSON-RPC)
```
- Il server è un **sottocomando della CLI inclusa** (`Xipper.app/Contents/MacOS/xipper mcp`), firmato e notarizzato con l'app.
- **Installazione con un clic** dalle Impostazioni, sezione Integrazioni:
  - per Claude Desktop, un **MCP Bundle `.mcpb`** (`server.type: "binary"`, `user_config` con le cartelle consentite);
  - per Claude Code, `claude mcp add --transport stdio --scope user xipper -- …/xipper mcp`, previa conferma dell'utente.
- **Sandbox:** il processo MCP lo avvia il client, non Xipper, quindi non eredita la sandbox. → Canale Developer ID **senza sandbox per il binario MCP**, con una allowlist applicativa. Un'eventuale edizione per il Mac App Store userebbe i security-scoped bookmark condivisi tramite App Group: più limitante, perché gli agenti non potrebbero passare path arbitrari.

### Tool esposti
| Tool | Input | Annotation |
|---|---|---|
| `archive_info` | `path` | readOnly |
| `archive_list` | `path`, `cursor?`, `limit?` (200), `glob?` | readOnly, paginato |
| `archive_test` | `path`, `password_ref?` | readOnly, lungo, con progress |
| `archive_extract` | `path`, `destination`, `entries?[]`, `overwrite?`=false, `password_ref?` | destructive se `overwrite` |
| `archive_create` | `sources[]`, `output`, `format`, `level?`, `encrypt?`, `password_ref?` | non distruttivo (fallisce se `output` esiste) |
| `archive_read_entry` | `path`, `entry`, `max_bytes?` | readOnly (testo o immagini piccole) |

Ogni tool restituisce `structuredContent` più un breve riepilogo testuale. I lavori lunghi inviano `notifications/progress` e rispettano `notifications/cancelled`; l'estensione Tasks è prevista per la v2. Le resources (`xipper://archive/{path}/entry/{entry}`) sono opzionali.

### Sicurezza (obbligatoria)
1. **Allowlist di cartelle** scelte dall'utente in Xipper.app o nel `.mcpb`. Ogni path passa per `realpath` e viene confrontato per prefisso; tutto il resto è rifiutato.
2. **Stesse protezioni dell'estrazione manuale** (§7): zip-slip, symlink esterni, zip-bomb, quarantena, setuid rimosso. In più limiti specifici per MCP: dimensione totale e numero di voci.
3. **Password mai nel contesto dell'LLM:**
   - di base si usa `password_ref`, che punta a una voce del Portachiavi creata dall'utente in Xipper;
   - in alternativa il server chiede via XPC a Xipper.app di mostrare un `SecureField` nativo;
   - una password in chiaro come parametro è disattivata di default;
   - le password non compaiono mai nei risultati né nei log.
4. **Operazioni distruttive** (overwrite) solo con conferma esplicita tramite elicitation sì/no. Se il client non supporta la conferma, l'operazione viene rifiutata.
5. **Modalità sola lettura** attivabile: restano esposti solo `info`, `list`, `test` e `read_entry`.
6. **Registro di audit** in JSONL (`~/Library/Logs/Xipper/mcp-audit.jsonl`), visibile nell'app e senza segreti.

### Pianificazione
Dopo il core (fase 1) e prima dell'app: fase **1.5** "CLI + MCP", stimata in 1–2 settimane. Test di conformità con un client MCP di riferimento, usato solo in CI.

> Fonti: changelog della specifica MCP 2026-07-28 e trasporto stdio (modelcontextprotocol.io); spec 2025-11-25 sull'elicitation; repository e `Package.swift` dello swift-sdk; 9to5Mac e AppleInsider (beta 26.1); Apple Newsroom (WWDC26); MANIFEST di MCPB; documentazione MCP di Claude Code. Da verificare: quale versione del protocollo usano oggi Claude Desktop e Claude Code.

---

## 7. Sicurezza

1. **Zip-slip / path traversal:** si rifiutano percorsi assoluti, segmenti `..` e symlink che puntano fuori dalla destinazione. L'estrazione passa per `openat` con `O_NOFOLLOW`.
2. **Zip-bomb:** si controllano il rapporto di espansione e la dimensione totale dichiarata rispetto a quella reale; voci sovrapposte nella directory centrale vengono rilevate; limiti configurabili con conferma dell'utente.
3. **Quarantena:** se l'archivio ha l'attributo `com.apple.quarantine`, lo si **propaga** a tutti i file estratti, così Gatekeeper e XProtect controllano gli eseguibili. Molti archiviatori se ne dimenticano.
4. **Password:**
   - ZIP: **AES-256 (AE-2)** di default. ZipCrypto è disponibile solo in modalità "compatibilità" con un avviso esplicito, perché si rompe con un attacco a testo in chiaro noto.
   - 7z: AES-256 con **intestazioni cifrate** di default, così i nomi dei file non sono visibili senza password.
   - La password non va mai su disco né nei log; buffer azzerati dopo l'uso.
5. **Verifica:** controllo CRC/MAC di tutte le voci senza scrivere su disco ("Testa archivio"); manifest opzionale `SHA256SUMS`; in v2 dati di recupero **PAR2** (formato aperto) per riparare archivi danneggiati.
6. **Fuzzing** del parser di ogni formato (libFuzzer o fuzzing con Swift Testing) in CI. È obbligatorio per un programma che apre file non fidati.

---

## 8. Architettura e stack

```
┌─────────────────────────────────────────────────────────┐
│  Zipper.app (SwiftUI, macOS 15+)                         │
│  ├─ Finder Sync Ext   ├─ QuickLook Ext  ├─ FSKit Ext      │
│  ├─ App Intents       ├─ Thumbnail Ext  ├─ CLI (helper)   │
├─────────────────────────────────────────────────────────┤
│  ZipperKit (Swift framework, condiviso da tutti i target)│
│  ├─ Container: ZIP · 7z · TAR · CPIO · AAR               │
│  ├─ Pipeline: scheduler P/E, back-pressure, progress     │
│  ├─ Crypto: AES-CTR/CBC, PBKDF2, HMAC (CryptoKit/CC)     │
│  ├─ Safety: path sanitizer, bomb guard, quarantine       │
│  └─ Metadata: xattr, ACL, NFC/NFD, AppleDouble           │
├─────────────────────────────────────────────────────────┤
│  ZipperCodecs (C, SwiftPM targets, link statico)         │
│  ├─ di sistema: Compression, libz, libbz2                │
│  └─ vendorizzati: zstd · xz/liblzma · LZMA SDK · libdeflate · brotli │
│  └─ nostri: CRC32/CRC32C NEON+PMULL                      │
└─────────────────────────────────────────────────────────┘
```

- **Linguaggi:** Swift 6 (strict concurrency) per app e container; C per i codec vendorizzati e per le poche routine NEON scritte a mano. Rust è stato scartato: aggiunge una toolchain e un FFI senza un vantaggio netto qui.
- **Target minimo: macOS 26**, aggiornato dopo lo studio della UI: Liquid Glass è nativo, FSKit e App Intents sono maturi, e c'è Swift 6. Solo `arm64`, senza binario universale: è una scelta esplicita.
- **Build:** Xcode con il core in un pacchetto SwiftPM, quindi testabile da riga di comando.
- **Test:**
  - round-trip contro un corpus;
  - interoperabilità con file creati da 7-Zip, WinRAR (ZIP), Info-ZIP, Windows Explorer e Archive Utility;
  - fuzzing;
  - benchmark in CI su un Mac M-series.
- **Distribuzione:**
  - **Primaria:** Developer ID con notarizzazione e Sparkle… ⚠️ Sparkle è una dipendenza di terzi. In alternativa un updater minimale scritto da noi (feed firmato EdDSA), oppure solo il Mac App Store.
  - **Mac App Store:** possibile, ma la sandbox impedisce di scrivere "accanto" all'archivio senza un permesso dell'utente sulla cartella (Keka lo risolve chiedendo l'accesso alla cartella home). FSKit e la CLI vanno verificati rispetto alle regole del MAS.

---

## 9. Roadmap proposta

| Fase | Contenuto | Stima indicativa (1 sviluppatore) |
|---|---|---|
| **0. Spike** ✅ | Benchmark dei codec (sistema contro vendorizzati) su M-series, prototipo di ZIP parallelo, decisione A/B, **scelta del nome** → [SPIKE_FASE0.md](SPIKE_FASE0.md) | completata il 21/10/2026 |
| **1. Core** ✅ | XipperKit: ZIP/ZIP64 (lettura e scrittura, AES), TAR, gzip/bzip2/xz/zstd, sicurezza, verifica, CLI → [FASE1.md](FASE1.md) | completata il 21/10/2026 (restano alcuni punti rimandati) |
| **1.5 CLI + MCP** ✅ | Server MCP `xipper mcp` (2026-07-28 + 2025-11-25), 9 tool, allowlist, sola lettura, `password_ref` nel Portachiavi, conferme via elicitation/MRTR, audit, `.mcpb` (§6-ter) | completata il 21/10/2026 → [FASE1.md](FASE1.md) |
| **1.6 Genomica: BGZF** ✅ | Compressione e decompressione BGZF parallele, verifica BGZF/BAM/BCF, conversione gzip↔BGZF, indice `.gzi`, preferenza "Genomica", `xipper bgzip` (§4.4) | completata il 21/10/2026 → [FASE1.md](FASE1.md) |
| **1.7 Genomica 2 (GA4GH, locale)** ✅ | Creazione di tabix/CSI compatibile htslib (query identiche a `tabix`), verifica degli indici `.tbi`/`.csi`/`.bai`/`.gzi`/`.crai`, verifica strutturale di CRAM 3.0/3.1 e di VCF.gz/BCF, manifest sha-256/md5/crc32c (JSON DRS, `sha256sum`/`md5sum`); CLI `xipper tabix`/`index-check`/`manifest`, MCP `genomics_index`/`genomics_check`/`checksum_manifest` (§4.6) | completata il 21/10/2026 → [FASE1.md](FASE1.md) (Finder: con l'app) |
| **G0 MPEG-G** | Verifica legale di brevetti e licenze e acquisto dello standard; implementazione solo dopo (§4.5) | in parallelo, non tecnica |
| **2. App v1** 🚧 | UI SwiftUI con Liquid Glass (crea, estrai, sfoglia, verifica, password), Finder Sync, Quick Look, App Intents, Keychain | beta4 pubblicata il 21/10/2026; distribuzione solo DMG su GitHub (niente Developer ID); restano i test manuali di Touch ID, trascinamento e Comandi Rapidi, i feedback dei tester e la nuova grafica → [FASE2.md](FASE2.md), [docs/ROADMAP.md](docs/ROADMAP.md) |
| **3. 7z** ✅ | 7z completo (LZMA2, PPMd, BCJ-ARM64, AES, intestazioni cifrate, multi-volume) | completata il 21/10/2026 in XipperKit, CLI e MCP (l'app la integra a parte) → [FASE1.md](FASE1.md) |
| **4. v2** | ⭐ **Primo: montaggio dell'archivio come volume con FSKit** (sola lettura; ZIP, tar, 7z, XIZ). ⭐ Poi **ottimizzazioni in assembler ARM64/NEON (e GPU dove misurabile)** sui punti caldi: decodifica LZMA/LZMA2 e deflate, match finder, Huffman/FSE, CRC/XXH, AES, con percorso portabile di riserva, benchmark e test di equivalenza (§5.3). Poi XIZ stabile, PAR2, modifica in place, cartelle sorvegliate, **RAR in sola lettura (clean-room, §4.2)**, ISO. Ordine e dettagli in [docs/ROADMAP.md](docs/ROADMAP.md) | aperta |

---

### Nuovo formato XIZ (studio del 21/10/2026, BETA dal 21/10/2026)
Nome ed estensione: **XIZ**, **`.xiz`** (`.xip` è già di Apple; `.xiz` è usata solo dagli strumenti di ZynAddSubFX, con cui non c'è ambiguità: riconosciamo i file dai byte iniziali e dichiariamo il tipo `app.xipper.xiz`). La fase 1 del piano (MVP non cifrato) è nell'app come funzione BETA, da attivare in Impostazioni › Generali; vedi [FASE2.md](FASE2.md). Un formato di archivio proprio, che unisce blocchi indipendenti con indice in coda, deduplicazione, ordinamento per similarità, dizionari addestrati e cifratura autenticata di dati e nomi: [docs/reports/Nuovo formato di compressione Xipper.md](docs/reports/Nuovo%20formato%20di%20compressione%20Xipper.md). È un lavoro successivo alla v1; ZIP, 7z e tar restano i formati di scambio.

---

## 10. Decisioni aperte

1. ~~Nome del prodotto~~ → **Xipper**, bundle `Xipper.app` (21/10/2026). Restano la ricerca formale del marchio (EUIPO/UIBM/USPTO) e la verifica del nome su App Store Connect.
2. ~~Livello di autoinclusione~~ → **B**, codec permissivi vendorizzati (21/10/2026).
3. **Canale di distribuzione:** Developer ID, Mac App Store o entrambi? Lo studio MCP (§6-ter) spinge verso Developer ID.
4. ~~RAR~~ → **sola lettura, clean-room** (21/10/2026), §4.2.
5. **MPEG-G:** avviare la verifica legale G0 (GenomSys, Philips, LUH), oppure tenerlo in osservazione e puntare su BGZF (ed eventualmente CRAM)?
6. ~~Modello di business~~ → **gratuito e open source, licenza MIT** (decisa il 21/10/2026, file `LICENSE`). Motivazioni:
   - **Compatibilità:** tutte le dipendenze sono permissive (zstd BSD-3, libdeflate MIT, liblzma 0BSD, ed eventualmente libarchive BSD-2 per RAR), quindi MIT non crea attriti.
   - **LGPL e app macOS:** la LGPL richiede che l'utente possa ricollegare una versione modificata della libreria. Con un bundle Swift che contiene tutto in modo statico, e a maggior ragione con il Mac App Store (DRM e firma), rispettarla è macchinoso; molti progetti LGPL infatti non possono andare sul MAS.
   - **Diffusione:** con MIT XipperKit è riusabile ovunque, anche in altre app e strumenti di genomica, ed è il modo più rapido per farsi adottare.
   - Se si vuole che le modifiche a XipperKit restino aperte, l'alternativa intermedia è **MPL-2.0**: copyleft solo sui file modificati, compatibile con il link statico e con il MAS.
   - **Conseguenze:**
     - repository pubblico;
     - distribuzione tramite GitHub Releases con Developer ID e notarizzazione, cask Homebrew e un'eventuale versione gratuita sul MAS;
     - Sparkle (MIT) diventa accettabile per gli aggiornamenti, perché si può vendorizzare;
     - eventuali donazioni o sponsor;
     - l'open source **non** esenta dai brevetti, quindi per MPEG-G il passo G0 resta obbligatorio.

---

## Fonti

- GNUstep Zipper.app: https://wiki.gnustep.org/index.php/Zipper · pacchetto Debian: https://packages-pkgmirror-csail.debian.org/nl/trixie/zipper.app
- unxed/zipper (Go): https://pkg.go.dev/github.com/unxed/zipper@v0.1.71
- Mr. Zipper (MAS): https://apps.apple.com/us/app/mr-zipper-7z-rar-7zip/id471561604?mt=12 · https://alternativeto.net/software/mr-zipper/about
- Smart Zipper: https://www.waerfa.com/smart-zipper · https://www.alternativeto.net/software/smart-zipper/about/
- Password Zipper (MAS): https://apps.apple.com/app/id627776008
- "Zipper" iPad (scheda ZIP Extractor): https://apps.apple.com/app/id6443985825
- Zippr: https://www.mactech.com/2019/01/28/appyogi-software-launches-zippr-for-the-mac
- UnZipper: https://mac.softpedia.com/get/Utilities/UnZipper.shtml
- Zipper 1.9.8 (JVN): https://jvn.jp/en/reply/DID96055463.html
- Mail Zipper: https://www.capterra.co.uk/software/1036561/mail-zipper
- Marchio IZIP: https://trademark.justia.com/855/13/izip-85513174.html
- Concorrenti: https://setapp.com/app-reviews/winzip-alternatives-for-mac · https://alternativeto.net/news/2025/9/betterzip-5-4-brings-new-file-previews-finder-style-selection-macos-26-support-and-more · https://www.macitbetter.com/whats-new-in-betterzip-4/ · https://www.softpedia.com/reviews/mac/keka-review-537996.shtml

*Nota: le informazioni tecniche sui framework Apple, sulle istruzioni ARMv8 e sui formati vengono da conoscenza consolidata, non da ricerche fatte per questo documento. La fase 0 (spike) deve verificarle con benchmark e prove di build, in particolare il supporto di Compression.framework per brotli/LZMA e i vincoli di FSKit e della sandbox MAS.*

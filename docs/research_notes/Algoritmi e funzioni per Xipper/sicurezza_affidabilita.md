# Sicurezza, integrità e affidabilità per archiviatori (input per release future di Xipper)

Contesto: Xipper ha già cifratura AES, cronologia firmata Ed25519, firma AEA, recovery PAR2, controlli su path traversal e link che escono dalla destinazione in estrazione, chiavi in Keychain, suite di test di stabilità e sicurezza. Queste note raccolgono minacce, mitigazioni e pratiche dei concorrenti. Ricerca aggiornata a novembre 2026, fatta con circa 17 query/fetch: alcune affermazioni vengono solo da snippet o da fonti secondarie e sono segnalate come tali.

## 1. CVE recenti degli archiviatori (2022–2026): cause e lezioni

### Takeaway
Quasi tutti i CVE sfruttati davvero negli archiviatori sono **errori logici sulla risoluzione dei percorsi** (symlink, ADS, spazi finali, normalizzazione) o **mancata propagazione dei metadati di sicurezza** (MotW o quarantena). I bug di memoria nei decoder sono numerosi ma raramente sfruttati in campagne reali. Per Xipper la superficie più critica resta quindi la logica di estrazione e dei metadati, non i codec.

### Cited Findings
- **7-Zip CVE-2025-0411 (MotW bypass)**: prima della 24.09, 7-Zip non propagava il Mark-of-the-Web ai file estratti da archivi annidati due volte ("double-encapsulated"). CVSS 7.0. Sfruttato come zero-day dal 25/09/2024 contro organizzazioni ucraine, con payload SmokeLoader camuffato da PDF. Corretto nella 24.09 (novembre 2024). — [The Hacker News](https://thehackernews.com/2025/02/russian-cybercrime-groups-exploiting-7.html)
- **7-Zip CVE-2025-11001 (symlink traversal)**: la gestione dei symlink negli archivi ZIP permette di scrivere fuori dalla cartella di estrazione, con possibile esecuzione di codice. Bug introdotto nella 21.02 e corretto nella 25.00. Scoperto da Ryota Shiga (GMO Flatt Security). Esiste un PoC pubblico e l'NHS England riporta sfruttamento attivo. CVSS 7.0. Secondo SecurityWeek la scrittura riesce solo se 7-Zip gira con privilegi amministrativi, e i prodotti che incorporano 7-Zip devono aggiornarsi anche loro. — [SecurityWeek](https://www.securityweek.com/recent-7-zip-vulnerability-exploited-in-attacks/amp/); [SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2025-11001/)
- **WinRAR CVE-2023-38831**: errore logico. WinRAR rimuove gli spazi finali durante la normalizzazione del percorso, ma poi chiama `ShellExecuteExW` con il percorso non normalizzato, per esempio "poc.png ". In questo modo viene eseguito lo script dell'attaccante, contenuto in una cartella con lo stesso nome del file esca. Secondo TAG basta uno spazio in qualunque punto dell'estensione. — [Google TAG](https://blog.google/threat-analysis-group/government-backed-actors-exploiting-winrar-vulnerability/)
- CVE-2023-38831 è stato sfruttato come zero-day da aprile 2023, scoperto da Group-IB il 10/07/2023 e corretto in WinRAR 6.23. Lo hanno poi usato attori statali russi e cinesi. — [Group-IB](https://group-ib.com/blog/cve-2023-38831-winrar-zero-day/); [The Hacker News](https://thehackernews.com/2023/08/winrar-security-flaw-exploited-in-zero.html); [The Register](https://www.theregister.com/2023/10/18/china_russia_winrar)
- **WinRAR CVE-2025-8088**: path traversal tramite Alternate Data Streams (ADS). Un archivio costruito ad hoc fa usare a WinRAR, RAR, UnRAR e UnRAR.dll per Windows un percorso definito nell'archivio al posto di quello indicato dall'utente. RomCom (gruppo allineato alla Russia) lo ha usato come zero-day per depositare DLL e LNK in %TEMP% e nella cartella Startup. ESET lo ha scoperto il 18/07/2025 e lo ha segnalato il 24/07. La 7.13 beta 1 è uscita lo stesso giorno, la 7.13 stabile il 30/07/2025. BI.ZONE ha attribuito lo stesso metodo anche al cluster Paper Werewolf. — [ESET WeLiveSecurity](https://www.welivesecurity.com/en/eset-research/update-winrar-tools-now-romcom-and-others-exploiting-zero-day-vulnerability/); [BleepingComputer](https://www.bleepingcomputer.com/news/security/details-emerge-on-winrar-zero-day-attacks-that-infected-pcs-with-malware/)
- **WinRAR CVE-2025-6218**: path traversal simile, divulgato il 19/06/2025, circa un mese prima di CVE-2025-8088. — [ESET WeLiveSecurity](https://www.welivesecurity.com/en/eset-research/update-winrar-tools-now-romcom-and-others-exploiting-zero-day-vulnerability/)
- **libarchive CVE-2025-5915**: heap over-read in `copy_from_lzss_window()` del lettore RAR, causato da un blocco filtro che supera la finestra LZSS. CVSS 6.6, corretto in libarchive 3.8.0 (PR #2599). Il record CVE riporta CWE-122 (overflow) anche se la descrizione parla di over-read. — [Red Hat](https://access.redhat.com/security/cve/CVE-2025-5915)
- **macOS Archive Utility, famiglia di bypass della quarantena**: CVE-2021-1810 (percorsi oltre 886 caratteri non ereditavano `com.apple.quarantine`), CVE-2022-22616 (ZIP che aggira Gatekeeper), CVE-2022-32910 (archivio con due o più elementi alla radice, o nome `.app.zip`: la cartella estratta non riceve la quarantena; corretto in macOS 11.6.8 e 12.5). — [WithSecure](https://labs.withsecure.com/blog/the-discovery-of-cve-2021-1810); [The Hacker News](https://thehackernews.com/2022/10/details-released-for-recently-patched.html)
- **CVE-2026-28849**: secondo SentinelOne, un altro bypass di Gatekeeper in cui i file di uno ZIP costruito ad hoc non ereditano sempre `com.apple.quarantine`. Corretto in macOS Sequoia 15.7.8 e Sonoma 14.8.8. Non verificato su fonte Apple. — [SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2026-28849/)

### Inferences
- Lezione 1: **una sola funzione canonica per "percorso di destinazione finale"**, usata sia per il controllo sia per la scrittura. CVE-2023-38831 nasce dall'uso di due rappresentazioni diverse dello stesso percorso (normalizzata e grezza). Xipper dovrebbe validare e scrivere usando lo stesso oggetto, idealmente con `openat`/`O_NOFOLLOW` relativi a un descrittore della directory radice. Così si evitano anche le race TOCTOU con i symlink creati durante l'estrazione.
- Lezione 2: i symlink vanno estratti **per ultimi**, oppure va verificato a ogni componente che nessun antenato sia un link appena creato (è la classe di 7-Zip CVE-2025-11001). Xipper ha già controlli sui link che escono dalla destinazione: conviene aggiungere test con catene di symlink (link verso directory seguito da un file scritto "attraverso" il link) e con hard link.
- Lezione 3: su macOS gli equivalenti degli ADS sono **resource fork e attributi estesi** (`..namedfork/rsrc`, AppleDouble `._file` negli ZIP). Vanno trattati come dati non fidati: niente percorsi né nomi derivati da xattr e nessun ripristino ingenuo di xattr sensibili come `com.apple.quarantine` rimosso o `com.apple.ResourceFork`.
- Lezione 4: nomi con spazi o punti finali, caratteri Unicode confondibili, RTLO (U+202E) e nomi riservati Windows. Xipper ha già i "Windows-safe names" (commit 1eb10d5). Conviene estenderli a un avviso UI sui nomi con estensione ingannevole (doppia estensione, RTLO).
- Priorità: ALTA.

### Gaps
- Non ho verificato i dettagli di eventuali CVE 2024–2026 di Info-ZIP unzip. La CVE storica rilevante è CVE-2019-13232 (zip bomb sovrapposti, vedi sezione 2). Non ho trovato nuovi CVE unzip 2022–2026 durante la ricerca.
- Non ho elencato tutti i CVE libarchive del 2024–2025: ne esistono altri (per esempio nei lettori RAR, 7z e ISO) non verificati qui. Va controllato il registro di sicurezza del GitHub di libarchive. È rilevante per macOS perché `bsdtar` e Archive Utility usano libarchive.

## 2. Zip bomb, voci sovrapposte e ambiguità tra parser ZIP

### Takeaway
Le difese "classiche" (limite di nesting, rapporto di compressione) non bastano. Servono il **rilevamento della sovrapposizione degli intervalli di byte** delle voci e una **politica di parsing rigorosa e univoca**: il central directory è autorevole, va riconciliato con gli header locali, e le discrepanze si rifiutano. Lo studio USENIX Security 2025 mostra che quasi ogni coppia di parser ZIP è ambigua.

### Cited Findings
- Fifield, "A better zip bomb" (USENIX WOOT '19): zip bomb **non ricorsivo** ottenuto sovrapponendo i file nel contenitore. Si espande completamente in un solo round di decompressione, usa solo DEFLATE ed è compatibile con la maggior parte dei parser. ClamAV risultava vulnerabile. — [USENIX WOOT19](https://www.usenix.org/conference/woot19/presentation/fifield); [paper PDF](https://www.usenix.net/system/files/woot19-paper_fifield_0.pdf)
- Mitigazione in Info-ZIP unzip (CVE-2019-13232, patch di Mark Adler): rifiuta lo ZIP se una voce si sovrappone a un'altra o al central directory, tenendo traccia degli intervalli di byte già coperti. La patch è stata applicata anche in Debian LTS. — [patch Alpine](https://git-old.alpinelinux.org/aports/tree/main/unzip/CVE-2019-13232.patch?h=v3.10.5); [Freexian ELA-141-1](https://www.freexian.com/lts/extended/updates/ela-141-1-unzip)
- You, Chen, Wang, Duan (Tsinghua), "My ZIP isn't your ZIP: Identifying and Exploiting Semantic Gaps Between ZIP Parsers", USENIX Security 2025, Distinguished Paper. Il fuzzer differenziale **ZipDiff** ha testato 50 parser in 19 linguaggi: quasi tutte le coppie presentano ambiguità. Gli autori individuano 14 tipi di ambiguità in 3 categorie (10 nuovi), 5 scenari reali (bypass dei gateway email, spoofing di documenti Office, impersonazione di estensioni VS Code, manomissione di JAR annidati firmati con verifica Spring Boot superata) e 7 mitigazioni. Ne sono seguiti 3 CVE (Go, LibreOffice, Spring Boot). — [USENIX](https://www.usenix.org/conference/usenixsecurity25/presentation/you)
- CVE-2025-8291 (Python zipfile): l'offset nello ZIP64 End of Central Directory Locator non viene validato, e il parser assume che il record sia quello immediatamente precedente. Uno scanner conforme può quindi vedere contenuti diversi. — [SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2025-8291/)
- CVE-2025-54368 (uv): gli ZIP remoti venivano letti in streaming senza riconciliare le voci con il central directory. Uno stesso digest poteva così espandersi in modo diverso a seconda dell'installer. Corretto in uv 0.8.6. CVE-2025-13327 (uv): differenziali da commenti nel central directory e da nomi file con byte NUL, corretti in uv 0.9.6. — [Astral advisory](https://astral.sh/blog/uv-security-advisory-cve-2025-54368); [Corgea CVE-2025-13327](https://corgea.com/advisories/vulnerabilities/CVE-2025-13327)

### Inferences
- Checklist di parsing "strict" per Xipper (priorità ALTA, costo basso):
  1. Central directory autorevole. Per ogni voce, header locale e voce CD devono coincidere su nome, metodo, dimensioni e CRC, flag di cifratura, campi ZIP64. Se non coincidono, rifiutare oppure segnalare l'archivio come "ambiguo".
  2. Rilevamento di intervalli di byte sovrapposti (voce/voce e voce/CD), come nella patch di unzip.
  3. Un solo EOCD valido. Rifiutare dati dopo l'EOCD che contengano un secondo EOCD, commenti contenenti firme e locator ZIP64 incoerenti.
  4. Rifiutare nomi duplicati, nomi con NUL, separatori `\` e percorsi assoluti. Normalizzazione Unicode NFC/NFD coerente con APFS per individuare collisioni tra nomi canonicamente equivalenti.
  5. Limiti configurabili su dimensione totale espansa, numero di voci, rapporto di espansione per voce e globale, profondità di nesting. Il conteggio va fatto durante lo streaming (byte effettivamente prodotti), senza fidarsi delle dimensioni dichiarate.
- Opportunità: integrare ZipDiff, o un corpus ispirato, nella suite di test di sicurezza di Xipper, verificando che Xipper e `bsdtar`/Archive Utility vedano lo stesso contenuto o che Xipper rifiuti.
- Per la cronologia firmata Ed25519 e la firma AEA: se si firma un archivio ZIP, la firma deve coprire i **byte canonici effettivamente estratti** (o l'intero file), non solo il CD. Altrimenti ricompare la classe Spring Boot o uv.

### Gaps
- Non ho estratto l'elenco dettagliato dei 14 tipi di ambiguità né delle 7 mitigazioni del paper ZipDiff (l'abstract non li riporta). Va letto il PDF.
- Non ho trovato dati su ambiguità analoghe per 7z, RAR o tar. Per tar le differenze PAX/GNU sono note, ma non le ho verificate qui.

## 3. Supply chain (xz-utils), fuzzing e riscritture memory-safe

### Takeaway
Il backdoor xz (CVE-2024-3094) era nascosto in **file binari di test** e in **logica di build presente solo nei tarball di release**. Un progetto che fa vendoring di codec deve importare da tag git verificati, non da tarball, e trattare i blob di test come codice. Le riscritture memory-safe dei codec (zlib-rs) hanno raggiunto la parità di prestazioni e vengono adottate in produzione (Firefox).

### Cited Findings
- xz 5.6.0 e 5.6.1: il payload stava in file di test binari (per esempio `bad-3-corrupt_lzma2.xz`), estratti ed eseguiti da `m4/build-to-host.m4`. L'iniezione era limitata a build Debian/Fedora (Linux + GCC). La 5.6.1 aggiungeva la possibilità di eseguire altri script dai blob di test. — [SentinelOne](https://www.sentinelone.com/blog/xz-utils-backdoor-threat-actor-planned-to-inject-further-vulnerabilities/)
- Lezioni segnalate dalle analisi: i tarball di release possono differire dal repository, quindi vanno confrontati tarball e tag git. La sola code review non basta. I fixture binari vanno esaminati. Servono build riproducibili, verifica delle firme dei pacchetti, SBOM e provenance. (Fonte secondaria.) — [SentinelOne](https://www.sentinelone.com/blog/xz-utils-backdoor-threat-actor-planned-to-inject-further-vulnerabilities/); [Penligent (secondaria)](https://www.penligent.ai/hackinglabs/es/?p=2978)
- zlib-rs (Trifecta Tech): nel 2025 è stato adottato da oltre 3000 progetti, ha raggiunto prestazioni alla pari con zlib-ng ed è arrivato alla 0.6, prima versione con API stabile e completa. — [Trifecta Tech](https://trifectatech.org/projects/zlib-rs/); [Current zlib-rs performance](https://trifectatech.org/blog/current-zlib-rs-performance/)
- Firefox 151 usa zlib-rs per gzip. La sostituzione "drop-in" ha richiesto un fix per i CPU Intel di 13ª/14ª generazione con una piccola aggiunta di codice `unsafe`. Le prestazioni dipendono da istruzioni specifiche della CPU. — [Phoronix](https://www.phoronix.com/news/Mozilla-Firefox-zlib-rs-Usage); [Trifecta perf](https://trifectatech.org/blog/current-zlib-rs-performance/)
- Trifecta Tech ha un'iniziativa "data compression" con workplan pubblico che va oltre zlib. — [Trifecta data compression](https://trifectatech.org/initiatives/data-compression)

### Inferences
- Per Xipper (priorità ALTA, costo basso):
  - Vendoring da **commit o tag git firmati** con hash fissato in un manifest (SBOM, per esempio CycloneDX o SPDX). Mai da tarball di release, oppure tarball confrontato con il tag.
  - Escludere dal vendoring i blob di test upstream e gli script di build autotools/m4 che non servono: compilare i codec con il proprio sistema di build (Xcode/SwiftPM).
  - Verificare con `diff` automatico in CI ogni aggiornamento dei codec, con revisione obbligatoria dei file binari.
  - Fuzzing locale dei parser e dei decoder vendorizzati (libFuzzer e ASan/UBSan sono disponibili con Xcode clang), con corpus da OSS-Fuzz quando esistono.
- Priorità MEDIA: dove Xipper usa decoder C o assembly NEON personalizzati (consentiti secondo la memoria di progetto), isolarli. Per esempio XPC service sandboxed per il decoding di formati esterni (RAR, 7z, ISO), così un bug di memoria non compromette l'app principale. È il pattern usato da browser e Quick Look.
- Swift è memory-safe per i parser di container. Scrivere in Swift i parser di header e metadati (ZIP, 7z, tar) e lasciare in C/NEON solo i kernel di decompressione riduce la superficie.

### Gaps
- Non ho verificato lo stato attuale della copertura OSS-Fuzz per zstd, libarchive e 7-Zip. 7-Zip upstream non risulta integrato in OSS-Fuzz per quanto ne so, ma è un'informazione non verificata.
- Non ho verificato lo stato di zip-rs (crate `zip`), né eventuali riscritture Rust di zstd e xz (per esempio `lzma-rs`, `zstd-rs` puro).

## 4. Mark-of-the-Web e quarantena macOS

### Takeaway
La propagazione della quarantena ai file estratti è un requisito di sicurezza, non un dettaglio: sia 7-Zip (CVE-2025-0411) sia Archive Utility (diversi CVE 2021–2026) sono stati aggirati proprio qui. Un archiviatore di terze parti su macOS **deve** copiare `com.apple.quarantine` dall'archivio a ogni elemento estratto, ricorsivamente e anche dentro gli archivi annidati.

### Cited Findings
- 7-Zip non propagava il MotW negli archivi annidati due volte (CVE-2025-0411). — [The Hacker News](https://thehackernews.com/2025/02/russian-cybercrime-groups-exploiting-7.html)
- Archive Utility: CVE-2021-1810 (percorsi oltre 886 caratteri senza quarantena), CVE-2022-32910 (archivi con più elementi alla radice o nome `.app.zip`, la cartella non viene marcata e Gatekeeper la ignora), CVE-2022-22616, e secondo SentinelOne CVE-2026-28849 (ereditarietà della quarantena incoerente). — [WithSecure](https://labs.withsecure.com/blog/the-discovery-of-cve-2021-1810); [The Hacker News](https://thehackernews.com/2022/10/details-released-for-recently-patched.html); [SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2026-28849/)
- Verifica: `xattr -p com.apple.quarantine <path>`; `spctl --assess --verbose=4 <App.app>`. — [SentinelOne](https://www.sentinelone.com/vulnerability-database/cve-2026-28849/)

### Inferences
- Requisiti per Xipper (priorità ALTA):
  1. Se l'archivio sorgente ha `com.apple.quarantine`, applicare lo stesso valore (stesso agent e timestamp, eventualmente aggiornando l'agent name a Xipper) a **ogni** file, cartella, symlink e bundle estratto, compresa la cartella contenitore creata.
  2. Propagare la quarantena anche quando Xipper apre un archivio annidato estratto in temporanea o in anteprima.
  3. Non ripristinare mai dall'archivio un valore di `com.apple.quarantine` (né la sua assenza) che sovrascriva quello ereditato. L'xattr di quarantena dentro l'archivio è input non fidato.
  4. Applicare la quarantena **prima** di rendere visibili i file (estrarre in staging e poi spostare), così da evitare finestre in cui un `.app` è eseguibile senza quarantena.
  5. Test di regressione per tutti i trigger noti: percorsi lunghi, più elementi alla radice, `.app.zip`, symlink, bundle, archivi annidati.
- Se Xipper diventa sandboxed (App Store, attualmente escluso secondo la memoria di distribuzione), l'impostazione `LSFileQuarantineEnabled` applica la quarantena automaticamente ai file creati. Fuori sandbox va fatto esplicitamente con `setxattr` o con le API `NSURL` `quarantinePropertiesKey`.
- Gatekeeper: dato che Xipper è distribuito come DMG self-signed, Xipper stesso arriva in quarantena. È utile documentare per l'utente come gestirlo, senza consigliare `xattr -cr` in generale.

### Gaps
- Non ho trovato una fonte Apple primaria che descriva esattamente quali xattr di quarantena debbano propagare le app di terze parti. Le linee guida derivano da comportamento osservato e CVE.
- Non ho verificato se le versioni recenti di macOS (Sequoia/Tahoe) impongano provenance (`com.apple.provenance`) in modo che interagisca con gli archiviatori.

## 5. Cifratura: ZIP AES, KDF di 7z e RAR5, Argon2, cifratura dei nomi, post-quantum

### Takeaway
I formati legacy usano KDF deboli rispetto allo stato dell'arte (ZIP AE-2: PBKDF2-SHA1 a 1000 iterazioni; 7z: SHA-256 iterato 2^19 volte; RAR5: PBKDF2-HMAC-SHA256 a 2^15 iterazioni di default). Nessuno usa una KDF memory-hard. Per il formato nativo di Xipper conviene una KDF memory-hard (Argon2id), cifratura AEAD con autenticazione anche di header e nomi, e un recipient ibrido post-quantum (ML-KEM-768 + X25519), già standard de facto in age v1.3.

### Cited Findings
- Kohno, "Analysis of the WinZip encryption method" (ePrint 2004/078, CCS 2004): AE-2 è essenzialmente encrypt-then-authenticate con AES-CTR e HMAC-SHA1 e l'impianto di base appare sicuro. Esistono però attacchi chosen-ciphertext che sfruttano l'interazione tra compressione e cifratura, e un attacco reso possibile da come WinZip ha corretto AE-1. Lezione: valutare il sistema nel suo insieme. — [IACR ePrint 2004/078](https://eprint.iacr.org/2004/078); [PDF](https://cryptosec.sysnet.ucsd.edu/miscpapers/winzip-ccs04.pdf)
- La ZipCrypto legacy resta vulnerabile ad attacchi known-plaintext. — [ElcomSoft 2026](https://blog.elcomsoft.com/2026/07/cracking-legacy-zip-encryption-the-known-plaintext-attack-and-why-it-still-sometimes-works/)
- 7z: KDF SHA-256 iterata, con iterazioni = 2^NumCyclesPower (default 19, cioè 524.288). ElcomSoft (2021) afferma che 7-Zip non usa salt. Il codice di zesven gestisce un salt di 0–16 byte (il formato lo prevede, ma 7-Zip lo lascia vuoto). — [ElcomSoft 2021](https://blog.elcomsoft.com/2021/04/breaking-rar5-and-7zip-passwords); [zesven source](https://docs.rs/crate/zesven/latest/source/src/crypto/mod.rs)
- RAR5: PBKDF2-HMAC-SHA256 con conteggio memorizzato come log2, default 2^15 (32.768). L'header contiene un valore di verifica della password. Il post ElcomSoft del 2021 attribuiva invece 2^19 a RAR5: le fonti sono in conflitto, e la più recente (2026) e il codice rar-stream indicano 2^15. — [ElcomSoft 2026](https://blog.elcomsoft.com/2026/07/the-rar-mystery-breaking-rar4-and-rar5-encryption/); [rar-stream source](https://docs.rs/rar-stream/5.3.2/src/rar_stream/crypto/mod.rs.html)
- age v1.3.0: chiavi post-quantum native (`age-keygen -pq`, recipient `age1pq1…` di circa 2000 caratteri, identità `AGE-SECRET-KEY-PQ-1…`). `age-inspect` mostra il tipo di recipient "mlkem768x25519". Il plugin `age-plugin-pq` porta il supporto a qualunque implementazione con plugin. Breaking change: con `-i` i file cifrati con passphrase vengono rifiutati. — [age GitHub](https://github.com/FiloSottile/age); [openSUSE changelog](https://src.opensuse.org/pool/age/src/branch/factory/age.changes)
- Lo schema è descritto come HPKE ibrido con ML-KEM-768 (fonte secondaria). — [x-cmd blog](https://www.x-cmd.com/blog/251230)
- pq-age (Python, terze parti) usa invece `mlkem1024-x25519-v1`, non interoperabile con age e rage. — [PyPI pq-age](https://pypi.org/project/pq-age/)

### Inferences
- Priorità ALTA:
  - Formato nativo di Xipper: Argon2id (parametri memorizzati nell'header e calibrati sul dispositivo, per esempio 256 MiB–1 GiB e circa 0,5–1 s su Apple Silicon), salt casuale di almeno 16 byte, AEAD (AES-256-GCM o ChaCha20-Poly1305) in chunk con nonce derivati e indice di chunk e flag "ultimo chunk" autenticati come in age/STREAM, per impedire troncamenti e riordinamenti.
  - **Cifrare indice e nomi file** di default quando c'è una password (7z `-mhe` e RAR `-hp` lo offrono; ZIP AE-2 non cifra nomi né metadati del central directory).
  - Compressione prima della cifratura: in un archivio offline il rischio di side channel stile CRIME è basso. La lezione Kohno è invece autenticare **prima** di decomprimere e non esporre errori diversi (oracolo) tra "MAC errato" e "decompressione fallita".
- Priorità MEDIA: in creazione di ZIP cifrati per compatibilità, usare solo AE-2 con AES-256 e avvisare che i nomi restano in chiaro. Non offrire mai ZipCrypto senza un avviso esplicito.
- Priorità MEDIA: un recipient a chiave pubblica ibrido **X25519 + ML-KEM-768** (FIPS 203), compatibile con age v1.3, per archivi condivisi. Xipper potrebbe anche adottare direttamente il formato age come "envelope" per la cifratura a chiave pubblica, invece di inventarne uno. Su Apple, CryptoKit espone ML-KEM e X-Wing su macOS 26 (da verificare). La firma Ed25519 della cronologia potrà essere affiancata da ML-DSA (FIPS 204) in un secondo momento: per le firme il rischio "harvest-now-decrypt-later" non si applica, quindi la priorità è minore.
- Le chiavi Keychain sono già presenti: si può valutare la protezione con Secure Enclave per le chiavi di firma (P-256 soltanto; Ed25519 non è supportata in Secure Enclave).

### Gaps
- Non ho trovato una fonte primaria per le iterazioni PBKDF2 di WinZip AE-2 (1000 è il valore comunemente citato dalla specifica WinZip, ma non verificato in questa ricerca).
- Non ho trovato archiviatori mainstream che adottino Argon2 (WinRAR, 7-Zip e WinZip non risultano farlo; non verificato).
- Non ho verificato la data esatta di rilascio di age v1.3.0 né le specifiche C2SP del recipient `mlkem768x25519`.
- NIST FIPS 203/204/205 (agosto 2024) non sono stati recuperati direttamente in questa ricerca.

## 6. Recovery: record RAR, PAR2, Reed–Solomon e fountain code; rilevamento del bit-rot

### Takeaway
PAR2, già in Xipper, resta lo standard aperto più diffuso (Reed–Solomon su GF(2^16), fino a 32.768 blocchi sorgente e 65.535 blocchi di recovery). Ha però limiti noti (in casi rari non è MDS) e PAR3 non è maturo. L'integrità per blocco con hash crittografici e lo "scrub" periodico sono importanti quanto la parità.

### Cited Findings
- PAR2: input divisi in blocchi di uguale dimensione, fino a 32.768 blocchi sorgente e 65.535 di recovery. PAR1 era limitato a 256 file in totale. PAR3 è indicato come formato futuro. — [Wikipedia Parchive](https://en.wikipedia.org/wiki/Parchive)
- Nel novembre 2008 è stato trovato un bug nell'implementazione Reed–Solomon di Parchive: in casi eccezionali non si comporta come codice MDS, quindi il principio "bastano N blocchi qualsiasi" non vale sempre. (Fonte 2009, in francese.) — [linuxfr.org](https://linuxfr.org/news/parchive-les-premices-dune-norme)

### Inferences
- Priorità MEDIA: il record di recovery **interno** all'archivio (stile RAR) è più comodo per l'utente, perché un solo file sopravvive alla copia. PAR2 esterno è più interoperabile. Xipper può offrire entrambi: PAR2 incorporato in coda, con hash per blocco nell'indice firmato, e PAR2 esterno per compatibilità con par2cmdline e MultiPar.
- Raccomandazioni:
  - Hash crittografico (BLAKE3 o SHA-256) **per chunk** nell'indice, coperto dalla firma Ed25519/AEA. Distingue corruzione e manomissione e permette la verifica parziale e la riparazione mirata.
  - Comando "Verifica/Scrub" schedulabile (bit-rot su dischi esterni e NAS), con report di quali chunk sono danneggiati e se la recovery può ripararli.
  - Ridondanza dell'indice: copia del central directory o dell'header in testa e in coda all'archivio. Un indice danneggiato rende inutile la parità sui dati.
  - Distribuire la parità in modo interleaved, per resistere a errori a raffica (settori consecutivi).
- Fountain code (RaptorQ, RFC 6330) sono interessanti per lo streaming e i trasferimenti, ma meno per l'archiviazione statica, dove Reed–Solomon con parametri fissi è più semplice e deterministico. Priorità BASSA.
- Per i dati genomici (BAM/CRAM da 12 GB, vedi memoria di progetto) la verifica per chunk permette di validare rapidamente porzioni grandi senza rileggere tutto.

### Gaps
- Non ho trovato fonti primarie sul formato del recovery record RAR5 (algoritmo, granularità, limite percentuale). RARLAB lo documenta nel manuale, non recuperato qui.
- Non ho trovato lo stato della specifica PAR3 (draft di Yutaka Sawada e Michael Nahas) né la sua adozione nel 2026.
- Non ho trovato studi quantitativi recenti sul tasso di bit-rot nei dischi consumer da citare.

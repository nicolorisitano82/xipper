# XIZ per l'informatica forense: analisi e progetto per Xipper 3.1

Stato: **bozza di analisi**, 02/11/2026. Nessuna riga di codice è stata scritta per questo documento.
Riferimenti interni: [XIZ_SPEC.md](XIZ_SPEC.md) (versione 1.4), [ROADMAP.md](ROADMAP.md) (2.6, 2.7, 3.0),
`Sources/XipperKit/Xiz/` (firme, marche temporali, prove), `Sources/XipperKit/Edit/ArchiveEditor.swift` (append).

Convenzioni del documento:

- **[Fatto]**: verificato nel codice o nella spec di Xipper, oppure in una fonte esterna citata.
- **[Proposta]**: idea di progetto, da discutere e misurare.
- **[Da verificare]**: affermazione plausibile che va controllata (in particolare quelle giuridiche, da far
  rivedere a un avvocato o a un consulente tecnico forense).

Richiesta del proprietario: usare gli archivi XIZ per l'analisi forense. Esempio: fare l'immagine di un
disco e creare un archivio validato, immutabile e firmato.

---

## 1. Obiettivo e casi d'uso

### 1.1 Obiettivo

Un file `.xiz` che contenga una copia forense e che, da solo, permetta di dimostrare:

1. **integrità**: la copia è identica alla sorgente al momento dell'acquisizione (hash della sorgente);
2. **attribuzione**: chi l'ha fatta, con quale strumento, su quale dispositivo, quando;
3. **storia**: chi l'ha ricevuta, aperta o integrata dopo, senza poter riscrivere il passato;
4. **ripetibilità**: un terzo, con uno strumento indipendente, ottiene lo stesso flusso e gli stessi hash.

Il formato non deve sostituire E01 per forza. Deve poter convivere: esportare verso E01/raw e importare da
E01/raw senza perdere gli hash originali.

### 1.2 Casi d'uso

| Caso | Sorgente | Cosa serve in più rispetto a un archivio normale |
|---|---|---|
| Acquisizione fisica | disco o chiavetta collegati al Mac, `/dev/rdiskN` | flusso unico di N byte, settori illeggibili, metadati del dispositivo, hash dell'intero flusso |
| Acquisizione di volume | una partizione (`/dev/rdiskNsM`) | come sopra, più la posizione nel disco |
| Acquisizione logica | cartelle, mailbox (mbox, `.emlx` di Mail, PST esportati), export di app | metadati del file system (date, xattr, permessi), elenco di ciò che è stato escluso |
| Catena di custodia | l'archivio stesso | ogni passaggio di mano registrato, firmato e datato |
| Consegna | perito, avvocato, tribunale, consulente di parte | cifratura per destinatario, consegna parziale, prova di un singolo file |

Fuori ambito: acquisizione della RAM, di dispositivi mobili (iOS/Android), di cloud e di rete. Questi casi
usano strumenti dedicati. Un loro output (file, cartelle, immagini) può però entrare in un XIZ forense come
acquisizione logica.

---

## 2. Stato dell'arte

### 2.1 Formati di immagine

| Formato | Origine | Caratteristiche rilevanti | Fonte |
|---|---|---|---|
| **dd / raw** (+ file `.md5`/`.sha1` a parte) | Unix | Copia bit a bit. Nessun metadato, nessuna compressione. Hash e log in file separati. È il formato più universale. | — |
| **E01 (EWF)** | ASR Data (formato SMART/Expert Witness), poi Guidance Software (EnCase) | Segmenti (`.E01`, `.E02`…), compressione zlib a chunk (32 KiB tipici), checksum Adler-32 per chunk, sezione con hash MD5 (e SHA-1 nelle versioni recenti) dell'intero flusso, sezione "header" con numero caso, esaminatore, note, sezione con gli errori di lettura. | [libewf](https://github.com/libyal/libewf), documentazione EWF del progetto libyal |
| **Ex01 (EWF2)** | EnCase 7 | Successore di E01: compressione bzip2 opzionale, cifratura. libewf lo legge; scrittura, bzip2 e cifratura Ex01 risultano non supportate o in corso. | [libewf](https://github.com/libyal/libewf) |
| **AFF4** | Cohen, Garfinkel, Schatz (2009); standard v1.0 nel 2017 | Contenitore ZIP con metadati RDF (Turtle), "map" per immagini sparse e composte, hash multipli, immagini a strisce dal 2022. Implementazioni: pyaff4, c-aff4, Evimetry. | [AFF4 Standard](https://github.com/aff4/Standard), [spec v1.0a](https://raw.githubusercontent.com/aff4/Standard/master/inprogress/AFF4StandardSpecification-v1.0a.md), [Library of Congress](https://loc.gov/preservation/digital/formats/fdd/fdd000413.shtml) |
| **SMART** | ASR Data | Formato da cui deriva EWF; oggi di nicchia. | — [Da verificare: fonte primaria] |

Osservazioni:

- **[Fatto]** E01 è lo standard di fatto in tribunale perché lo leggono tutti gli strumenti (EnCase, FTK,
  X-Ways, Autopsy/The Sleuth Kit tramite libewf). Il suo punto debole è che MD5 e Adler-32 non sono
  resistenti alle collisioni, e che il file non è firmato: chi modifica l'immagine può ricalcolare gli hash.
  L'integrità dipende dalla custodia dell'hash fuori dal file (verbale).
- **[Fatto]** AFF4 risolve meglio dell'E01 le immagini sparse e i metadati, ma ha poche implementazioni.
  È l'esempio più vicino a quello che XIZ dovrebbe fare, ed è anche l'esempio del rischio "formato nuovo"
  (§5.1).

### 2.2 Strumenti di acquisizione

| Strumento | Piattaforma | Formati | Note |
|---|---|---|---|
| **FTK Imager** (Exterro) | Windows, versione macOS a riga di comando | E01, raw, SMART, AFF (vecchie versioni) | Hash MD5 + SHA-1, verifica dopo l'acquisizione, campi del caso. Gratuito, chiuso. |
| **Guymager** | Linux | E01 (libewf), AFF, dd | Multithread, hash MD5/SHA-1/SHA-256, verifica rileggendo sorgente e immagine, file `.info` con log. Open source. |
| **ewfacquire** (libewf) | Linux, macOS | E01, Ex01 (parziale) | Riga di comando; chiede caso, esaminatore, note; registra gli errori di lettura. |
| **dc3dd** (DoD Cyber Crime Center) | Unix | raw | `dd` con hash al volo (`hash=sha256`), log (`log=`, `hlog=`), gestione degli errori di lettura, verifica. |
| **dd + sha256sum** | ovunque | raw | Il minimo accettato; tutto il resto è nel verbale. |

**[Da verificare]**: versioni correnti e funzioni esatte di ciascuno (per esempio quali hash calcola FTK
Imager per macOS). Da controllare sulle pagine ufficiali prima di citare il documento all'esterno.

### 2.3 Norme e linee guida

- **ISO/IEC 27037:2012**, "Guidelines for identification, collection, acquisition and preservation of
  digital evidence" ([iso.org](https://www.iso.org/standard/44381.html)). Principi: pertinenza,
  affidabilità, sufficienza; requisiti di verificabilità, ripetibilità e riproducibilità, giustificabilità.
  Completano la serie ISO/IEC 27041 (adeguatezza dei metodi), 27042 (analisi), 27043 (processi).
- **NIST SP 800-86** (2006), "Guide to Integrating Forensic Techniques into Incident Response"
  ([csrc.nist.gov](https://csrc.nist.gov/pubs/sp/800/86/final)): raccolta, esame, analisi, report; uso di
  write-blocker e di hash per la copia.
- **NIST CFTT** (Computer Forensics Tool Testing) pubblica i requisiti e i risultati delle prove degli
  strumenti di acquisizione; **NIST CFReDS** offre immagini di riferimento documentate
  ([cfreds-archive.nist.gov](https://cfreds-archive.nist.gov/)).
- **SWGDE**: best practice per l'acquisizione, utili come lista di controllo. [Da verificare: documento
  e versione da citare]

Requisiti tipici che ne derivano (sintesi, non testo normativo):

| Requisito | Pratica comune |
|---|---|
| Hash dell'intera sorgente | MD5 + SHA-1 per compatibilità storica, SHA-256 come hash forte; calcolati in lettura e ricalcolati sulla copia |
| Log di acquisizione | strumento e versione, inizio e fine, dispositivo, errori, hash, operatore |
| Metadati del caso | numero di caso, numero di reperto, esaminatore, descrizione, note |
| Verifica | rilettura della copia e confronto degli hash; meglio se con uno strumento diverso |
| Protezione della sorgente | write-blocker hardware, o almeno software; nessun montaggio in scrittura |
| Conservazione | copia di lavoro e copia master; supporto sigillato; registro di catena di custodia |

### 2.4 Quadro italiano

**[Fatto, con fonti secondarie; testo da verificare sulla Gazzetta Ufficiale o su Normattiva]**

- **L. 18 marzo 2008, n. 48**: ratifica la Convenzione di Budapest sulla criminalità informatica e
  modifica il Codice di procedura penale. Introduce l'obbligo di "misure tecniche dirette ad assicurare la
  conservazione dei dati originali e a impedirne l'alterazione" ([testo delle modifiche,
  Procura di Milano](https://www.procura.milano.giustizia.it/files/modifiche-p-p--legge-48.doc)).
- **c.p.p.**, articoli rilevanti:

| Articolo | Contenuto (in breve) |
|---|---|
| 244, c. 2 | Ispezione anche di sistemi informatici, con misure che conservino i dati originali e ne impediscano l'alterazione ([art. 244](https://miolegale.it/codici/codice-procedura-penale/art-244/)) |
| 247, c. 1-bis | Perquisizione di sistemi informatici, con le stesse misure ([art. 247](https://miolegale.it/codici/codice-procedura-penale/art-247/)) |
| 254-bis | Sequestro di dati presso i fornitori di servizi: acquisizione mediante copia "su adeguato supporto", con procedura che assicuri la conformità della copia all'originale e la sua immodificabilità ([art. 254-bis](https://www.avvocatoandreani.it/servizi/codice-procedura-penale/art-254-bis-cpp.html)) |
| 260, c. 2 | Copia dei dati sequestrati con procedura che ne assicuri conformità e immodificabilità |
| 354, c. 2 | Accertamenti urgenti della polizia giudiziaria: copia dei dati su adeguati supporti, conforme e immodificabile |
| 359 | Consulenti tecnici del pubblico ministero (accertamenti ripetibili) |
| 360 | Accertamenti tecnici **non ripetibili**: avviso alle parti, che possono nominare consulenti e assistere |

- **Ripetibilità**: se l'acquisizione produce una copia verificabile (hash) e la sorgente resta integra,
  l'accertamento è considerato ripetibile e la difesa può rifarlo. Un'acquisizione che altera la sorgente,
  o non si può ripetere (per esempio un SSD che cambia contenuto da solo, §3.3), rischia di ricadere
  nell'art. 360. La giurisprudenza richiede "misure tecniche e procedure idonee a conservare i dati
  originali e a garantire la conformità e immodificabilità delle copie", senza imporre uno strumento
  preciso (Cass. pen., sez. III, n. 37644/2015, [massima](https://brocardi.it/massimario/42498.html)).
- **eIDAS** (Reg. UE 910/2014, aggiornato dal Reg. UE 2024/1183): art. 41, la **validazione temporale
  elettronica qualificata** gode della presunzione di accuratezza della data e dell'ora e di integrità dei
  dati a cui si riferisce; art. 25, la firma elettronica qualificata equivale alla firma autografa. In
  Italia i prestatori qualificati (TSA) sono nell'elenco AgID/EU Trusted List (per esempio InfoCert, Aruba,
  Namirial). **[Da verificare]**: le regole tecniche nazionali (DPCM 22/02/2013) sulla conservazione delle
  marche temporali da parte del prestatore.

Conseguenza pratica: la legge italiana non chiede un formato, chiede **conformità e immodificabilità
dimostrabili**. Un formato nuovo è ammissibile in linea di principio, ma deve convincere il giudice e il
consulente della controparte (§5.1).

---

## 3. Mappatura sulle funzioni XIZ e lacune

### 3.1 Tabella riassuntiva

| Esigenza forense | Cosa offre XIZ 1.4 oggi [Fatto] | Lacuna | Gravità |
|---|---|---|---|
| Hash dell'intero flusso | SHA-256 per voce (`digest` 0x0008), ma HMAC se cifrato; SHA-256 in chiaro nel campo `proof` 0x0009 solo con `directory` | Niente MD5/SHA-1; niente hash della **sorgente** distinto dall'hash del contenuto archiviato; l'hash non è in un record leggibile senza password | alta |
| Accesso a offset casuali | Frame da 4 MiB, extents per voce, frame decompressi in parallelo | Funziona. Ma senza hash crittografico per frame, una lettura casuale è verificata solo con CRC32C (§3.2) | media |
| Aree sparse | nessuna (le zone di zeri si comprimono e si deduplicano, ma restano nei frame) | Manca un extent "zero/sparse" esplicito | bassa |
| Settori illeggibili | nessuna | Manca la mappa dei settori illeggibili e la convenzione sul riempimento | alta |
| Metadati del dispositivo | nessuna | Modello, seriale, firmware, capacità, geometria, SMART, interfaccia | alta |
| Metadati del caso e log | nessuna | Numero caso, reperto, esaminatore, note, log strutturato | alta |
| Firma con identità | Ed25519 per segmento, con etichetta libera (§13.5); chiavi in file o nel Portachiavi | Chiave grezza senza certificato: l'etichetta non prova l'identità. Niente firma qualificata, niente smart card | alta |
| Marca temporale | RFC 3161 facoltativa sulla firma del segmento, verifica CMS e fiducia nelle radici del Mac | La richiesta non supporta l'autenticazione (le TSA qualificate italiane di solito la chiedono); nessuna verifica dello stato "qualificato" | media |
| Catena di custodia | Segmenti in coda, firmati e concatenati (`previous`) | Un passaggio di mano senza modifiche al contenuto non ha un tipo di segmento dedicato | media |
| Immutabilità | Append-only: nulla di scritto cambia, tranne le key slot cancellabili (§13.7) | "Append-only" è una regola del writer, non una proprietà del file (§3.4) | media |
| Deduplica | FastCDC, file e chunk identici una sola volta | Va bene per l'integrità, ma concentra il rischio di danni (§3.5) | bassa |
| Cifratura per la consegna | AES-GCM, password Argon2id, destinatari X25519, k-di-n | Funziona; da definire cosa resta visibile senza chiave (§3.6) | bassa |
| Consegna parziale | Gruppi di accesso per cartella | Non si applica dentro un'immagine disco (una sola voce) | media |
| Prova di un singolo file | Prova Merkle RFC 6962 per voce, verificabile senza archivio né password | Solo per voci intere: non prova un file **ricavato** da un'immagine (§3.7) | media |
| Correzione degli errori | PAR2 accanto all'archivio; recovery record interno previsto nella 2.7 | Per un'evidenza conservata anni serve dentro il file | media |
| Lettore indipendente | Solo l'implementazione Swift di Xipper; spec pubblica in inglese | Nessuna seconda implementazione | alta |

### 3.2 Hash e integrità

**[Fatto]** Cosa copre la firma di un segmento (§13.5): il digest della directory, che contiene lo
SHA-256 di ogni catalogo di gruppo; il catalogo elenca ogni frame con il suo **CRC32C**, e ogni voce con
il suo SHA-256 di contenuto (in chiaro se l'archivio non è cifrato).

Conseguenze:

- Per un'immagine non cifrata la firma copre lo SHA-256 dell'intero flusso: una modifica si scopre
  **rileggendo tutto**.
- A livello di frame il legame è solo CRC32C, che non è crittografico. Chi modifica un frame può
  correggerne il CRC. Lo scopre solo la verifica completa dello SHA-256 della voce. Per un'immagine da
  2 TB questo significa che un accesso casuale (montaggio, analisi) non è verificato crittograficamente.
- Negli archivi cifrati il problema non c'è: AES-GCM autentica ogni frame e lo lega al suo indice (§6.4).

**[Proposta]** Nel profilo forense, una **tabella degli hash dei frame** (SHA-256 di ogni frame come
scritto, o un albero Merkle sui frame), coperta dalla firma. Così ogni lettura casuale si verifica in
O(4 MiB) e si può provare che un intervallo di settori appartiene all'immagine firmata (§3.7).

**[Proposta]** Un record "hash della sorgente" con MD5, SHA-1 e SHA-256 calcolati durante la lettura del
dispositivo, in chiaro e firmato, distinto dallo SHA-256 del contenuto archiviato. Devono coincidere
(SHA-256); MD5 e SHA-1 servono solo a confrontarsi con verbali e strumenti esistenti.

### 3.3 Settori illeggibili, aree sparse, SSD

- **Settori illeggibili** **[Proposta]**: come dc3dd ed ewfacquire, si riempiono di zeri nel flusso
  e si elencano in una mappa (offset, lunghezza, errore, tentativi). L'hash del flusso include gli zeri;
  la mappa dice quali byte non provengono dal disco. Senza mappa, gli zeri sarebbero indistinguibili da
  dati veri.
- **Aree sparse** **[Proposta]**: un tipo di extent "zero run" (nessun frame) per le aree tutte a zero.
  Riduce la dimensione del catalogo e la lettura; non cambia l'hash.
- **SSD con TRIM** **[Fatto, noto in letteratura]**: il controller può azzerare o rimappare i blocchi
  cancellati anche con un write-blocker, perché la garbage collection è interna al disco. Due acquisizioni
  dello stesso SSD possono dare hash diversi. Non è un problema del formato, ma il report deve dirlo: in
  quel caso la ripetibilità si basa sulla copia, non sulla sorgente.

### 3.4 Immutabilità: cosa vuol dire davvero

| Livello | Cosa garantisce | Cosa non garantisce |
|---|---|---|
| Formato append-only (XIZ §11) | Un writer conforme non riscrive nulla; la storia è nei footer precedenti | Chiunque può riscrivere il file con un altro programma |
| Firma concatenata (§13.5) | Ogni modifica a un segmento firmato si scopre; ogni segmento successivo è attribuito | Chi possiede la chiave può rifare l'archivio da capo e firmarlo di nuovo; la troncatura agli ultimi segmenti non si scopre senza un riferimento esterno |
| Marca temporale | La firma esisteva a quella data; una rifirma successiva avrebbe una data diversa | Nulla, se la marca non viene richiesta |
| Hash nel verbale | Il riferimento esterno che chiude la troncatura e la rifirma | — |
| Flag APFS `uchg`/`schg` (`chflags`) | Il file non si modifica per errore | `root` può toglierli (macOS gira normalmente a securelevel 0) [Da verificare] |
| Supporti WORM (BD-R, LTO WORM, S3 Object Lock in modalità compliance) | Immutabilità imposta dal supporto o dal servizio | — |

Messaggio da dare all'utente: **XIZ rende la manomissione evidente, non impossibile**. L'immutabilità
vera viene dal supporto e dal riferimento esterno (hash e marca temporale nel verbale).

**[Fatto]** Eccezione: le voci cancellabili (§13.7) sovrascrivono 60 byte in place. Nel profilo forense
**[Proposta]** vanno vietate.

### 3.5 Deduplica e ripetibilità

- **[Fatto]** La deduplica XIZ è senza perdita: il flusso ricostruito è identico byte per byte, e lo
  SHA-256 lo dimostra. Dal punto di vista probatorio equivale alla compressione di E01.
- Rischio: un frame danneggiato colpisce ogni punto del disco che lo riusa. Con l'immagine di un disco
  pieno di blocchi ripetuti, un solo frame perso può rendere illeggibili molte zone.
- Rischio di comprensione: spiegare a un giudice che "il settore X è memorizzato come riferimento al
  settore Y" è più difficile che spiegare la compressione.
- Limite tecnico: con chunk FastCDC da 64 KiB medi, un disco da 4 TB produce circa 64 milioni di extent
  da 12 byte, cioè circa 760 MB di catalogo, vicino al limite di 1 GiB (§5) [stima].

**[Proposta]** Nel profilo forense: deduplica a chunk **disattivata** per le immagini; restano gli extent
"zero run". Per le acquisizioni logiche la deduplica per file intero resta ammessa (è comune e facile da
spiegare). Con il recovery record della 2.7 il rischio del frame condiviso si riduce.

### 3.6 Cifratura e consegna

- **[Fatto]** Un archivio cifrato nasconde nomi, metadati e contenuto. Restano visibili superblock,
  parametri KDF, numero e dimensione dei frame, contatori del footer, e (con `directory`) firme ed etichette.
- **[Proposta]** Nel profilo forense restano **in chiaro e firmati**: record del caso (senza note
  riservate), hash della sorgente, mappa dei settori, log. Così chiunque riceva il file verifica
  integrità e firma senza poterne leggere il contenuto.
- **[Fatto]** Gruppi di accesso: utili nell'acquisizione logica (per esempio la cartella "Posta" al
  perito, "Documenti aziendali" alla parte). Non si applicano dentro un'immagine disco, che è una sola voce.
- **[Proposta]** Per la consegna parziale di un'immagine: estrarre i file dall'immagine (con
  The Sleuth Kit o con l'analisi dell'esaminatore) in un **archivio derivato**, che cita l'archivio
  sorgente e porta per ogni file una prova di provenienza (§3.7).

### 3.7 Prove di inclusione

- **[Fatto]** Oggi una prova (`xipper prove`) dimostra che una **voce** dell'archivio, con quel contenuto,
  è in un segmento firmato. È già utile per l'acquisizione logica: si consegna una sola email con la prova,
  senza consegnare la mailbox.
- **[Lacuna]** Un file recuperato da un'immagine disco non è una voce. Serve una prova che lo leghi ai
  settori dell'immagine: "i byte di questo file sono, in quest'ordine, i byte agli offset A–B, C–D
  dell'immagine firmata".
- **[Proposta]** Con la tabella degli hash dei frame (§3.2) la prova contiene i frame coinvolti (4 MiB
  ciascuno, eventualmente cifrati per il destinatario) e il loro percorso Merkle. Il verificatore controlla
  i frame, ne estrae gli intervalli e confronta l'hash del file. La prova rivela il contenuto dei frame
  interi, non solo del file: va detto nel report. Alternativa più fine: albero Merkle su blocchi da 4 KiB,
  al costo di 32 byte per blocco (8 GB per un disco da 1 TB): troppo, quindi no.

### 3.8 Firma, identità, marca temporale

- **[Fatto]** Firma Ed25519 con etichetta libera; chiavi in file o nel Portachiavi; marca RFC 3161 su
  SHA-256 della firma; verifica CMS e fiducia nelle radici del Mac (`XizTimestamp.trusted`).
- **[Lacuna]** L'etichetta non è un'identità. In un procedimento serve che la chiave sia legata a una
  persona: certificato X.509 di un prestatore qualificato, o almeno una chiave pubblica depositata.
- **[Lacuna]** In Italia le firme qualificate dei professionisti stanno su smart card o token (CNS,
  firma digitale) o in firma remota, con RSA o ECDSA; Ed25519 di solito non è disponibile. [Da verificare
  per i singoli prestatori]
- **[Lacuna]** `RFC3161.request` fa un POST senza credenziali. Le TSA qualificate italiane di norma
  richiedono un account (HTTP Basic o simile). [Da verificare]

---

## 4. Proposta per la 3.1

### 4.1 Profilo «XIZ forense»

**[Proposta]** XIZ 1.5 con un bit richiesto `forensic` (bit 6). Un lettore senza il bit rifiuta il file,
come oggi per `lzma2`. Richiede `directory` (firme, prove). Vincoli del profilo:

- ogni segmento **deve** essere firmato; niente voci cancellabili; niente deduplica a chunk nelle immagini;
- frame da 4 MiB allineati al flusso: il frame *i* di un'immagine copre i byte [4 MiB·i, 4 MiB·(i+1)),
  così l'offset si calcola senza catalogo e uno strumento esterno ritrova i dati anche da un archivio danneggiato;
- codec ammessi: store e zstd (LZMA2 è lento a decomprimere per l'analisi; LZRAVEN/LZMESH esclusi perché
  solo Apple).

Nuovi elementi, tutti in chiaro e coperti dalla firma del segmento (nella directory o in un blocco a
parte il cui SHA-256 è nella directory):

| Elemento | Contenuto |
|---|---|
| Voce `image` (tipo 3) | flusso di N byte; dimensione del settore logico e fisico; extent normali e `zero run`; offset della partizione se è un volume |
| Hash della sorgente | MD5, SHA-1, SHA-256 del flusso letto, con ora di inizio e fine |
| Tabella hash dei frame | SHA-256 di ogni frame come scritto, con radice Merkle |
| Mappa dei settori illeggibili | (offset u64, lunghezza u64, codice errore, tentativi, riempimento) |
| Record del dispositivo | modello, seriale, firmware, capacità, interfaccia (SATA/NVMe/USB/Thunderbolt), bridge USB, SMART (grezzo e decodificato), stato di cifratura (FileVault, Opal), write-blocker dichiarato |
| Record del caso | numero di caso, reperto, esaminatore, ente, luogo, descrizione, note pubbliche; note riservate in un campo cifrato |
| Log di acquisizione | JSON Lines: eventi con ora monotona e UTC, comandi, versioni (Xipper, macOS, hardware), errori |
| Segmento di custodia | nessun frame, nessuna modifica di contenuto: chi consegna, a chi, quando, perché, stato dei sigilli |

Il record del caso e il log sono anche **voci normali** (`case.json`, `acquisition.log`) dentro
l'archivio, così si estraggono con qualunque versione di Xipper.

### 4.2 Acquisizione su macOS

**[Proposta]**, con fatti tecnici da verificare a uno a uno su macOS 26/27.

1. **Dispositivo**: `diskutil list -plist` e `diskutil info -plist` per l'elenco; IOKit
   (`IOServiceMatching("IOMedia")`, proprietà del `IOBlockStorageDevice`/NVMe) per modello, seriale,
   firmware. SMART: disponibile per SATA e NVMe interni via IOKit; spesso **non** attraverso i bridge
   USB. [Da verificare: API pubbliche per NVMe SMART]
2. **Niente montaggio**: Disk Arbitration (`DARegisterDiskMountApprovalCallback`) per rifiutare il
   montaggio automatico del disco da acquisire, prima che venga collegato. Se è già montato, si smonta
   (`diskutil unmountDisk`) e si annota nel log. Il montaggio in sola lettura non basta: APFS e HFS+
   possono scrivere metadati (journal replay) anche così. [Da verificare per APFS]
3. **Write-blocker hardware** (Tableau, WiebeTech o simili): raccomandato e dichiarato nel record del
   dispositivo. Xipper non può verificarlo; registra il modello del bridge visto da IOKit.
4. **Lettura**: `/dev/rdiskN` (dispositivo a caratteri, senza cache), letture allineate al settore, in
   blocchi da 4 MiB; su errore si ripete a passi più piccoli fino al settore, poi zeri e voce nella mappa.
   Serve `root`: la CLI si lancia con `sudo`; l'app usa un helper privilegiato (`SMAppService`) o chiede
   di usare la CLI. Accesso completo al disco (TCC) da concedere al terminale o all'helper.
5. **Pipeline**: lettore → hash MD5/SHA-1/SHA-256 in parallelo → compressione frame in parallelo →
   scrittura. Checkpoint ogni 64 GiB come segmento firmato (riprendibile dopo un'interruzione).
6. **Verifica**: rilettura dell'archivio e confronto con l'hash della sorgente; facoltativa una seconda
   lettura del dispositivo (dice se la sorgente è stabile, utile per gli SSD).

Limiti da scrivere nel report e nell'interfaccia:

| Caso | Limite |
|---|---|
| SSD interno di Mac Apple Silicon o con chip T2 | Cifratura hardware sempre attiva con chiavi nel Secure Enclave: l'immagine fisica è cifrata e inutile fuori da quel Mac. Serve l'acquisizione logica (per esempio con "Condividi disco" da recoveryOS, che espone i file via SMB) o strumenti dedicati. [Da verificare per macOS 27] |
| SSD con TRIM | Contenuto dei blocchi liberi non stabile; hash di due acquisizioni possono differire (§3.3) |
| Dischi con cifratura hardware (Opal, BitLocker, FileVault esterno) | L'immagine contiene il cifrato; le chiavi sono fuori ambito |
| Dischi USB dietro bridge | Seriale e SMART possono essere quelli del bridge o mancare |
| HPA/DCO su dischi ATA | macOS non offre un modo standard per rilevarli: da segnalare come non verificato |

### 4.3 Acquisizione logica

**[Proposta]** `xipper acquire --logical SRC…`: come la creazione di oggi, più record del caso, log,
elenco degli errori di lettura per file, xattr e date (inclusa la data di creazione), elenco esplicito
dei file esclusi o illeggibili. Deduplica per file intero ammessa. Gruppi di accesso per la consegna
parziale.

### 4.4 Verifica indipendente

- `xipper verify --report report.pdf --json report.json archivio.xiz`: struttura, CRC, hash di ogni
  frame, SHA-256 del flusso, firme e catena, marche temporali, mappa dei settori, confronto con l'hash
  della sorgente. Esito per punto, non un solo "OK".
- `xipper verify --expect-sha256 HASH`: confronto con l'hash scritto nel verbale (riferimento esterno).
- La verifica non ha bisogno della password se l'archivio non è cifrato; se è cifrato verifica
  struttura e firme senza password, e il contenuto con la password.

### 4.5 Export e interoperabilità

| Direzione | Come | Nota |
|---|---|---|
| XIZ → raw | flusso su file o su stdout (`xipper export --raw`) | Sempre possibile; è la via di fuga se un tribunale non accetta XIZ |
| XIZ → E01 | scrittura EWF con hash MD5/SHA-1 e campi del caso | Implementazione propria o libewf (LGPL v3: da valutare con la regola "nessuna dipendenza a runtime") [Da verificare: licenza] |
| E01 → XIZ | lettura con verifica degli hash E01, record del caso importato, log dell'importazione | Utile per archiviare evidenze esistenti con firma e marca |
| Montaggio | Il montaggio WebDAV esistente espone `image.dd` in sola lettura | Autopsy, X-Ways ed EnCase leggono un raw da un volume montato; la scrittura va disattivata per i profili forensi |

**[Fatto]** Il montaggio di oggi è in lettura e scrittura con overlay copy-on-write (ROADMAP 2.0). Per
un archivio forense va forzata la sola lettura e ogni lettura va verificata con la tabella degli hash dei
frame.

### 4.6 CLI

```
xipper acquire  --device /dev/rdisk4 --case CASE.json --sign keychain:Esaminatore \
                --timestamp URL [--tsa-user U --tsa-password-stdin] -o reperto-12.xiz
xipper acquire  --logical ~/Export/Mail --case CASE.json --sign … -o reperto-13.xiz
xipper custody  reperto-12.xiz --from "Mario Rossi" --to "Laboratorio X" --note "sigillo 4471" --sign …
xipper verify   reperto-12.xiz --report report.pdf --json report.json [--expect-sha256 HASH]
xipper export   reperto-12.xiz --raw - | …          xipper export reperto-12.xiz --e01 out.E01
xipper prove    reperto-12.xiz --range 0x1F400000:65536 -o prova.json
```

### 4.7 Report di acquisizione

**[Proposta]** JSON firmato (lo stesso contenuto del record del caso, degli hash e del log) e un PDF
leggibile generato dal JSON. Il PDF riporta gli hash in esadecimale completo, la chiave pubblica del
firmatario, la marca temporale, i limiti noti (§4.2) e i comandi per rifare la verifica con strumenti
indipendenti (per esempio `xipper export --raw | sha256sum`). Il PDF si può firmare a parte con la firma
qualificata dell'esaminatore (PAdES), fuori da Xipper.

### 4.8 Lettore indipendente

**[Proposta]** `libxiz`: lettore in C (già previsto per XIG, fase X4 della ROADMAP), solo lettura,
senza dipendenze oltre zstd e una libreria SHA-256, con un comando `xizcat` che emette il flusso raw e
gli hash. Licenza permissiva. Serve a tre cose: una seconda implementazione per i periti, un plugin per
The Sleuth Kit/Autopsy, e la garanzia che il formato non dipende da Xipper. Meglio se scritto da una
persona diversa partendo **solo dalla spec**.

---

## 5. Rischi, limiti, domande aperte

### 5.1 Accettazione di un formato nuovo

- Un consulente della difesa può contestare uno strumento non validato. La risposta tipica è: spec
  pubblica, implementazione indipendente, prove documentate (stile NIST CFTT), export in raw/E01
  verificabile con strumenti noti.
- Strategia consigliata: nei primi anni consegnare **anche** l'hash del flusso raw, così chiunque può
  rifare la verifica con `sha256sum` sull'export, senza fidarsi di Xipper.

### 5.2 Spec e implementazione

- La spec XIZ è pubblica e in inglese (MIT). Per l'uso forense serve una versione congelata del profilo,
  con vettori di prova (archivi e hash attesi) e un registro delle modifiche.
- Una sola implementazione (Swift, solo macOS) è un punto debole: vedi §4.8.

### 5.3 Prestazioni

- SHA-256 su Apple Silicon usa le istruzioni ARMv8 SHA2: dell'ordine di 2 GB/s per core [stima, da
  misurare con il banco della 2.6]. MD5 non ha accelerazione hardware: circa 0,6–0,8 GB/s per core
  [stima]. MD5, SHA-1 e SHA-256 sullo stesso flusso sono tre calcoli seriali ciascuno, ma in parallelo tra
  loro: il limite è MD5.
- Un SSD NVMe esterno su Thunderbolt legge a 2–3 GB/s; via USB 3 10 Gb/s circa 1 GB/s. Quindi con MD5
  attivo il collo di bottiglia può essere l'hash, non il disco. Opzione: MD5/SHA-1 solo su richiesta.
- La compressione zstd a livello basso (3) supera il disco usando più core; dati già cifrati o
  compressi non si comprimono e si scrivono come `store`.
- Criterio: l'acquisizione deve andare almeno alla velocità di dc3dd con `hash=sha256` sulla stessa
  macchina.

### 5.4 Chiavi dell'esaminatore

- Ed25519 nel Portachiavi è comodo, ma la chiave non è legata a un'identità verificabile.
- Opzioni: (a) chiave nel Secure Enclave (P-256, non esportabile) con certificato rilasciato dall'ente;
  (b) smart card via CryptoTokenKit (PIV funziona nativamente; le carte di firma italiane richiedono
  driver del produttore [Da verificare]); (c) firma qualificata sul report PDF, fuori dal formato.
- Conseguenza sul formato: un secondo algoritmo di firma (`algorithm = 2`, ECDSA P-256 con catena X.509
  nel record) o una firma CAdES staccata sul digest del segmento.

### 5.5 Aspetti legali da far verificare

Da sottoporre a un avvocato penalista e a un consulente tecnico forense:

1. se un'acquisizione con Xipper, verificata con export raw + hash, soddisfa gli art. 247, 254-bis, 260
   e 354 c.p.p. senza ulteriori cautele;
2. quando l'acquisizione di un SSD diventa accertamento non ripetibile (art. 360);
3. valore della marca RFC 3161 qualificata applicata alla firma Ed25519 di un segmento, invece che a un
   documento firmato con firma qualificata;
4. se il segmento di custodia firmato può sostituire o solo affiancare il verbale cartaceo;
5. trattamento dei dati personali nelle copie (GDPR, art. 2-octies Codice privacy per i dati giudiziari)
   e conservazione delle chiavi;
6. testo esatto delle norme citate (§2.4), che qui provengono da fonti secondarie.

### 5.6 Altre domande aperte

- Nome e posizione del bit: `forensic` come bit richiesto o come profilo dichiarato in un campo?
- Le note riservate del caso vanno cifrate per il solo esaminatore o per un gruppo?
- Serve la suddivisione in più file (come `.E01`, `.E02`) per i supporti FAT32 o per i limiti di upload?
- Hash aggiuntivi (BLAKE3, SHA-3) previsti nello strumento di hash della 2.6: utili o solo rumore?

---

## 6. Piano a fasi e criteri di accettazione

Le fasi presuppongono la 2.7 (recovery record dentro XIZ) e usano il banco di misura della 2.6.

| Fase | Contenuto | Criteri di accettazione |
|---|---|---|
| F0 — Revisione | Questo documento rivisto dal proprietario; domande §5.5 inviate a un esperto | Decisioni scritte sui punti §5.6 |
| F1 — Spec | Profilo forense in XIZ_SPEC.md (§15): voce `image`, extent `zero run`, tabella hash dei frame, mappa settori, record, segmento di custodia | Vettori di prova pubblicati; un lettore 1.4 rifiuta i file nuovi con messaggio chiaro |
| F2 — Acquisizione da file | `xipper acquire` su un file raw (nessun dispositivo) | Hash MD5/SHA-1/SHA-256 identici a `md5`, `shasum -a 1`, `shasum -a 256` sui dataset CFReDS e su immagini sintetiche; export raw identico byte per byte |
| F3 — Acquisizione da dispositivo | `/dev/rdiskN`, Disk Arbitration, IOKit, settori illeggibili | Su chiavette e dischi di prova: hash uguali a dc3dd ed ewfacquire (stessa sorgente, stesso istante); nessuna scrittura sulla sorgente (verifica con write-blocker hardware e confronto prima/dopo); disco con settori guasti simulati (o dispositivo `dm-flakey` in VM Linux, letto via rete) con mappa uguale al log di dc3dd |
| F4 — Firma, marca, custodia | Firma con certificato, TSA con autenticazione, `xipper custody` | Marca di una TSA qualificata verificata; catena di 5 passaggi di mano verificata; manomissione di un byte, troncatura e rifirma rilevate (le ultime due con l'hash del verbale) |
| F5 — Verifica e report | `xipper verify --report`, PDF e JSON | Report che elenca ogni controllo; errori iniettati (frame alterato con CRC corretto) rilevati dalla tabella hash dei frame |
| F6 — Interoperabilità | Export E01, import E01, montaggio in sola lettura | E01 esportato aperto da Autopsy/The Sleuth Kit e da `ewfverify` con hash uguali; stessa analisi (elenco file con `fls`) su raw, E01 ed XIZ montato |
| F7 — libxiz | Lettore C indipendente e `xizcat` | Legge tutti i vettori di prova; hash uguali a Xipper su CFReDS; fuzzing senza crash |
| F8 — Prestazioni | Misure su M-series | Velocità ≥ dc3dd `hash=sha256` sulla stessa macchina e sorgente; numeri in BENCHMARK.md |

Dataset di riferimento: NIST CFReDS ([cfreds-archive.nist.gov](https://cfreds-archive.nist.gov/)),
per esempio "Data Leakage Case" (immagine raw di circa 21 GB), più immagini sintetiche costruite per il
test (zeri, rumore, file system APFS/HFS+/FAT/NTFS/ext4, blocchi duplicati). Gli hash ufficiali vanno
presi dalle pagine NIST, non da fonti terze.

Come per le altre versioni: ogni funzione con test automatici; ciò che si prova solo a mano
(dispositivi reali, write-blocker, TSA qualificata) va annotato nel kit di prova della versione.

---

## 7. Riepilogo delle lacune principali

1. **Metadati forensi assenti**: nessun record del caso, del dispositivo, del log, nessun hash della
   sorgente (MD5/SHA-1/SHA-256) in chiaro e firmato, nessuna mappa dei settori illeggibili.
2. **Identità del firmatario debole**: Ed25519 con etichetta libera, senza certificato, smart card o
   firma qualificata; TSA senza autenticazione.
3. **Integrità per accesso casuale**: i frame sono legati alla firma solo via CRC32C; serve una tabella
   di hash crittografici dei frame, che abilita anche le prove su intervalli di settori.

Seguono: un lettore indipendente (libxiz), l'export E01, il montaggio forzato in sola lettura e il
recovery record interno (2.7).

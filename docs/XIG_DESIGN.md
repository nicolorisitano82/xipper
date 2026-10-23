# XIG: profilo genomico nativo di XIZ (opzione b), disegno

*Stato: bozza di disegno, 23/10/2026. Base: [XIZ_GENOMICS_STUDY.md](XIZ_GENOMICS_STUDY.md) §2.2 (opzione b), §3 (brevetti), §4 (librerie); [XIZ_SPEC.md](XIZ_SPEC.md) 1.2.*

> **Decisione del proprietario (23/10/2026).** Per XIG si adotta l'opzione (b), e il proprietario **accetta il rischio brevettuale** che lo studio le attribuisce (medio-alto: US11763918, EP3526706, EP3526711/09 e la domanda pendente US20200051665). Accettare il rischio non toglie le regole del §3.3 dello studio: questo disegno le applica tutte, e il §9 le verifica una per una. Non è un parere legale.

---

## 0. Sintesi

- **Cos'è.** XIG è XIZ con un tipo di entry nuovo, l'**insieme di allineamenti**: i record di un BAM, SAM o CRAM conservati non come file ma come **serie per campo**, a **blocchi di record** in ordine di coordinata. Ogni serie va in frame suoi, compressi con i codec di htscodecs (rANS Nx16, aritmetico adattivo, fqzcomp_qual, tokenizzatore dei nomi), già vendorizzati in Xipper.
- **Cosa guadagna rispetto a CRAM 3.1** (lo stesso modello di record, gli stessi codec):
  - **granularità separate**: i campi "caldi" (posizione, flag, CIGAR, mate) in **slice da 10.000 record**, quelli "freddi" e voluminosi (qualità, nomi, tag) in **span da 100.000**, dove fqzcomp e il tokenizzatore rendono di più. In CRAM le due cose sono legate: 10k → 100k vale circa il −10% (htslib), ma peggiora le query di regione;
  - **lettura per campo**: una query di sole posizioni legge pochi KB; `flagstat` non tocca qualità né nomi;
  - tutto il resto di XIZ: cifratura per frame, riferimento deduplicato per coorte, accesso remoto, più file nello stesso archivio.
- **Quanto** [stima, da verificare con B3, §8]: dal 5 al 10% meno di CRAM 3.1 normal, cioè dal 30 al 50% di BAM.
- **Cosa costa:**
  - l'export non è byte-esatto: si riottiene un BAM, SAM o CRAM **equivalente nei record**, verificabile con un digest dei record (§6.3);
  - un lettore XIZ 1.2 rifiuta l'archivio (bit obbligatorio nuovo);
  - un decoder di record in ogni linguaggio di lettura (C, Java, Python): è il costo principale (§10).
- **Il formato dei file resta `.xiz`**: XIG è un profilo, segnalato dai bit di funzione; un archivio può contenere insieme allineamenti XIG, VCF, FASTA e file qualsiasi.

---

## 1. Ambito

| In | Fuori (per ora) |
|---|---|
| Letture allineate da BAM, SAM, CRAM 2.1–3.1, ordinate per coordinata (o non ordinate: §3.5) | Varianti: VCF/BCF restano entry normali, con l'indice dell'opzione (a); un profilo colonnare per le varianti è la fase 4 dello studio, separata |
| Letture non mappate, in coda, nell'ordine d'ingresso | FASTQ non allineati (domanda aperta, §11): oggi entry normali (zstd o BGZF) |
| Header SAM completo (`@HD @SQ @RG @PG @CO`) | Qualità con perdita (solo lossless; §9 regola 5) |
| Tutti i tag ausiliari, compresi `MD`/`NM` (conservati, non ricalcolati: §4.6) | Riferimento incorporato a segmenti (§9 regola 4) |
| Riferimento esterno per MD5/refget, o un'entry FASTA dell'archivio; modalità senza riferimento | Modifica "in place" di un insieme (si riscrive l'entry) |

---

## 2. Vocabolario

Il vocabolario è quello di CRAM e degli archivi (studio §3.3, regola 6). Ogni termine ha un antenato preciso:

| Termine XIG | Significato | Da dove viene |
|---|---|---|
| **record** | una lettura allineata (riga SAM) | SAM/BAM |
| **slice** | da 1 a 10.000 record consecutivi (default), per i campi caldi | CRAM (slice) |
| **span** | da 1 a 16 slice consecutive (default 10), per i campi freddi | nuovo nome, stesso concetto del "container" multi-slice di CRAM e del row group di Parquet |
| **serie** | i valori di un campo per tutti i record di una slice o di uno span, in ordine di record | CRAM (data series); Goby, Parquet (column chunk) |
| **gruppo** | un insieme di serie lette insieme (posizione, sequenza, qualità, nomi, tag) | studio §2.3 |
| **frame** | il frame XIZ (§4 della spec) che contiene **una** serie di **una** slice o di **uno** span | XIZ |
| **XGI** | l'indice di regione e la mappa delle serie dell'insieme | CRAI, BAI, tabix |

Non si usano "access unit", "descriptor", "class", "dataset group", "master index table".

---

## 3. Modello dei record

### 3.1 Base: il modello di record di CRAM 3.1

XIG riusa **la semantica delle data series di CRAM 3.1** (CRAMv3 §8–10), già implementata nell'encoder e nel decoder Swift di Xipper (`Sources/XipperKit/Genomics/CRAM/`). Cambia solo il contenitore: niente blocco core a bit, niente codifiche Huffman, beta o gamma, niente compression header per container. Ogni serie è un **flusso di byte** con una codifica fissa (§3.3) e il codec del suo frame.

Vantaggi:
- l'encoder BAM→serie e il decoder serie→BAM esistono già quasi per intero in Swift (`CRAMEncoder.readFeatures`, `CRAMDecoder`);
- la conversione CRAM→XIG non deve rifare l'allineamento delle feature;
- il modello ha prior art pubblica dal 2011 (CRAM 1.0) al 2022 (CRAM 3.1).

### 3.2 Serie

| Gruppo | Serie (nomi CRAM) | Contenuto | Granularità | Codec di default |
|---|---|---|---|---|
| **P** posizione | `BF` flag BAM · `CF` flag CRAM · `RI` ref id (solo slice multi-ref) · `RL` lunghezza · `AP` posizione (delta in slice ordinata) · `MQ` qualità di mappatura · `RG` read group | per record | slice | rANS Nx16 o1 (`AP`, `RL`: con pack/RLE automatici) |
| **M** mate | `MF` flag del mate · `NS` ref del mate · `NP` posizione del mate · `TS` template size | per record, **sempre "detached"** (§9 regola 2) | slice | rANS Nx16 o1 |
| **F** feature | `FN` numero · `FC` codice · `FP` posizione · `DL` lunghezza di delezione · `RS` skip · `PD` padding · `HC` hard clip | per record | slice | rANS Nx16 o1 |
| **S** sequenza | `BS` codice di sostituzione · `BA` basi · `IN` inserzioni · `SC` soft clip · `BB` blocchi di basi | per record | slice | aritmetico o1 (`BA`, `IN`, `SC`); rANS o1 (`BS`) |
| **Q** qualità | `QS` (una stringa per record, `RL` byte) | per record | **span** | fqzcomp_qual |
| **N** nomi | `RN` | per record | **span** | tokenizzatore 3 (con aritmetico) |
| **T** tag | `TL` riga di tag · una serie per chiave e tipo (`NMc`, `MDZ`, `XAZ`…), come i content id dei tag in CRAM | per record | **span** (tag piccoli e caldi come `NM`, `AS`: slice, se il writer lo sceglie) | zstd 19 per le stringhe, rANS o1 per gli interi, scelta a campione |

- **La scelta della granularità è per serie e scritta nell'XGI** (§5): il lettore non la presuppone. I default sopra sono raccomandazioni per i writer.
- Una serie vuota (nessun valore nella slice o nello span) non ha frame.
- Uno span non attraversa i confini di riferimento solo se il writer lo vuole: non serve alla correttezza.
- Limite: un frame XIZ decomprime al più 64 MiB. Il writer chiude uno span quando una sua serie supera 32 MiB non compressi (letture lunghe: ONT, PacBio), e lo segna nell'XGI.

### 3.3 Codifica dei valori nelle serie

- Interi senza segno: **uint7** di CRAM 3.1 (LEB128 a 7 bit, big-endian come in CRAM 3.1 §2.3).
- Interi con segno (`AP` delta, `TS`, `NP` relativo): zigzag poi uint7.
- `AP`: in una slice con un solo riferimento e posizioni non decrescenti, delta dalla posizione precedente (la prima è assoluta, dal campo `start` della slice); altrimenti assoluta. Il modo è nel descrittore di slice (§5.2).
- Stringhe di byte: terminate da 0 (`RN`, `IN`, `SC`, tag `Z`) o con lunghezza uint7 (`BB`, tag `B`, `H`), come in CRAM.
- `QS`: `RL` byte per record, concatenati; per i record senza qualità (`*`), il flag CRAM `CF` bit 0 lo dice e non si scrive niente, come in CRAM 3.1.
- La **matrice di sostituzione** (`BS`) e il **dizionario delle righe di tag** (`TL`) sono nel descrittore di slice o di span (§5.2): servono a decodificare e sono piccoli.

### 3.4 Riferimento

- Con riferimento, le basi uguali al riferimento non si scrivono: le feature `X`/`B`/`I`/`S`… lo descrivono, come in CRAM.
- Ogni `@SQ` porta `M5` (MD5 della sequenza normalizzata), e se disponibile il digest refget `SQ.`+sha512t24u, nel tag `references` (studio §2.4, tag `0x000B`).
- Il lettore cerca la sequenza: 1) un'entry FASTA dell'archivio con lo stesso MD5; 2) la cache locale (`REF_PATH`/`REF_CACHE`); 3) refget, solo con opt-in e un URL dell'utente (STUDIO §4.6).
- **Senza riferimento** (`CF` bit "no ref" per slice, come CRAM con `RR=0`): basi verbatim in `BA`. Costa circa il 25–40% in più sulla sequenza [stima], resta lossless.
- **Niente riferimento incorporato a segmenti** dentro l'insieme (§9 regola 4): se l'utente vuole il riferimento nell'archivio, è un'entry FASTA intera, deduplicata per coorte.

### 3.5 Ordine dei record

- **Ordinato per coordinata** (`@HD SO:coordinate`): slice per riferimento; i non mappati in coda, nell'ordine d'ingresso. È il caso delle query di regione.
- **Non ordinato o per nome** (`SO:queryname`, `unsorted`): l'ordine d'ingresso si conserva, le slice sono multi-riferimento, l'XGI non serve per le regioni (resta per le serie). Mai riordinare (§9 regola 3).

### 3.6 `MD` e `NM`

Si conservano come tag, verbatim: l'equivalenza dei record è stretta (§6.3). Un'opzione futura "ricalcola MD/NM" (come `samtools calmd`) li toglierebbe, solo se l'utente lo chiede, e allora l'export non è più identico nei tag.

---

## 4. Formato: cosa cambia in XIZ

| Elemento | Valore | Effetto sui lettori 1.2 |
|---|---|---|
| `required_features` bit 3 `genomic_codecs` | codec 2–5 nei frame; entry di tipo 3 | rifiutano l'archivio con un messaggio chiaro |
| `version_minor` | 3 | — |
| `optional_features` bit 1 `genomic` | l'archivio contiene XGI e tag genomici | — |
| Codec dei frame | `2` rANS Nx16 · `3` aritmetico adattivo · `4` fqzcomp_qual · `5` tokenizzatore 3. `0` store e `1` zstd restano | — |
| Tipo di entry `3` **insieme di allineamenti** | nessun extent; il contenuto si ricostruisce dalle serie (§6) | — |
| Tag `0x8009 alignment` (critico) | `u8 version (1)` · `u8 export_hint` (1 BAM, 2 CRAM, 3 SAM: il formato d'origine) · `xgi` = n × (`frame u32`, `offset u32`, `length u32`), l'extent del blob XGI | obbligatorio per il tipo 3 |
| Tag `0x000B references` | come nello studio §2.4 | — |
| Tag `0x000D record_digest` | 32 byte: SHA-256 della forma canonica dei record (§6.3); HMAC-SHA-256 se cifrato, come il tag `digest` | — |

### 4.1 Payload dei codec nuovi

Ogni frame con codec 2–5 contiene **un flusso htscodecs così com'è** (i loro header portano già ordine, striping, pack, RLE, parametri del modello): `rans_compress_4x16`, `arith_compress_to`, `fqz_compress`, `tok3_encode_names`. `usize` è la lunghezza decompressa, come per zstd. Il CRC32C e l'AEAD dei frame non cambiano (§4, §6.4 della spec).

**Dipendenze tra frame.** Solo fqzcomp ne ha: per decodificare `QS` di uno span servono le lunghezze dei record (`RL`) e il bit READ2/reverse di `BF` delle slice dello span. È scritto nella spec del codec, ed è il motivo per cui `RL` e `BF` stanno nel gruppo P (sempre letto per primo).

### 4.2 Lettura parziale

La regola "§4.2 bis" dello studio (sottointervalli di un frame `store` non cifrato) non serve a XIG: ogni frame è già una sola serie di una sola slice o span.

---

## 5. XGI v2: indice e mappa delle serie

Un blob compresso con zstd, puntato dal tag `alignment` dell'entry. Non è un'entry a sé (i suoi byte sono dati non referenziati per un lettore 1.2, cosa ammessa da XIZ 1.1).

### 5.1 Struttura

```
magic "XGI2" · u16 version = 2
sam_header        frame list: il testo dell'header SAM, in frame zstd (anche > 64 MiB)
n_series          u16; per serie: name (2–4 byte ASCII, es. "AP", "NMc"), u8 granularity (0 slice, 1 span), u8 group
n_slices          u32
slices            n_slices × slice descriptor (§5.2)
n_spans           u32
spans             n_spans × span descriptor (§5.3)
pages             indice di regione paginato (§5.4)
```

### 5.2 Descrittore di slice

`ref_id i32` (−1 non mappati, −2 multi-ref) · `start u64` · `end u64` (1-based, inclusivo, come CRAI) · `n_records u32` · `first_record u64` (ordinale nell'insieme) · `flags u8` (bit 0 `AP` delta, bit 1 senza riferimento) · `sub_matrix [5]` · `span u32` · per ogni serie di granularità slice presente: `series u16`, `frame u32`.

### 5.3 Descrittore di span

`first_slice u32` · `n_slices u16` · `tag_lines` (dizionario `TL` dello span) · per ogni serie di granularità span presente: `series u16`, `frame u32`.

### 5.4 Indice di regione

- Pagine di al più 1.024 slice, in ordine; per pagina: `ref_id`, `start` minimo, `max_end` cumulativo, extent della pagina.
- Una query `ref:s-e` seleziona le slice con `ref_id == ref ∧ start ≤ e ∧ end ≥ s`: la sovrapposizione standard di CRAI e BAI. **Nessuna estensione della finestra per distanze tra coppie** (§9 regola 2).
- Con l'accesso remoto: pagina di primo livello → pagina → frame dei gruppi richiesti (studio §4.1, 3–4 round trip a freddo).

---

## 6. Lettura, export, verifica

### 6.1 Query

```
regions(entry, "chr7:55019017-55211628", groups = {P, M, F, S})  →  record
```

1. XGI → slice toccate (§5.4).
2. Per ogni slice: i frame dei gruppi richiesti; per i gruppi di span (Q, N, T), i frame dello span e l'offset dei record della slice dentro lo span (somma dei `n_records` delle slice precedenti nello span; per `QS` anche la somma delle `RL`).
3. Decodifica: le serie si scorrono in parallelo, record per record, come in CRAM. I record fuori dalla regione si scartano.

Il costo di leggere solo la regione nelle serie di span: si decodifica lo span intero della serie (fino a 100k record) per usarne una parte. È il prezzo del rapporto migliore; per Q e N vale circa 1–3 MB per span [stima]. Uno span da 10 slice si può ridurre per archivi pensati per query fini.

### 6.2 Export

`xipper extract` su un'entry di tipo 3 scrive il formato di `export_hint` (o quello scelto): BAM (BGZF, livello di default), CRAM 3.1 (con l'encoder esistente) o SAM. Xipper presenta l'operazione come **conversione** ("Esporta come BAM…"), non come estrazione byte-esatta (studio §5.4).

### 6.3 Equivalenza e `record_digest`

- **Forma canonica di un record**: il record BAM non compresso (`block_size` escluso) con il `bin` ricalcolato e i tag nell'ordine d'origine. Tipi interi dei tag: quelli d'origine (`c C s S i I`), che XIG conserva.
- `record_digest` = SHA-256 di: l'header SAM in testo, poi le forme canoniche di tutti i record in ordine.
- `xipper test` ricalcola il digest dalle serie; `xipper verify-against x.bam` lo confronta con quello del file d'origine. È la garanzia "lossless" al posto del byte-esatto.

### 6.4 Cifratura

Invariata: AES-GCM per frame. Poiché ogni frame è una serie, una query di posizioni non scarica né decifra qualità e nomi. Una cifratura **per campo** (chiavi diverse per Q e N) è possibile in seguito con un keys block esteso; non è in questa versione.

---

## 7. Implementazione in Xipper (Swift)

| Componente | Base esistente | Lavoro |
|---|---|---|
| Lettura BAM, SAM, CRAM → `AlignmentRecord` | `BAMReader`, `CRAMDecoder`, `CRAMFileReader` | nessuno |
| Record → serie | `CRAMEncoder.readFeatures` e `Streams` (oggi a content id) | serie per slice e per span, codifica §3.3, matrice e dizionario per slice/span |
| Codec 2–5 | htscodecs vendorizzato (`CHtsCodecs`) | wrapper per frame; scelta automatica dei parametri a campione (come `cram_compress_block` di htslib) |
| Writer XIZ | `XizWriter` (frame, catalogo, cifratura, dizionari) | entry di tipo 3, frame con codec nuovi, XGI, tag; bit di funzione |
| Reader | `XizArchive`, `CRAMDecoder` | serie → record; query di regione; export BAM/CRAM/SAM |
| App e CLI | conversione BAM↔CRAM esistente (app, CLI, MCP) | "Archivia come XIG", "Esporta come BAM/CRAM", query di regione nel browser |
| Test | `CRAMTests` (interop con samtools) | round trip BAM→XIG→BAM con `record_digest`; `samtools view` identico sull'export; regioni contro `samtools view x.bam region`; fuzz |

---

## 8. Validazione prima di estendere ad altri linguaggi

Il guadagno di (b) è una stima. Prima di scrivere decoder in C, Java e Python:

| # | Misura | Soglia |
|---|---|---|
| **B3** | XIG contro CRAM 3.1 normal e archive, su NA12878 30x chr20 e HG002 2×250 chr20 (studio §5.3): dimensione, tempo di scrittura e di lettura completa | **≥ 5% più piccolo di CRAM 3.1 normal** a velocità di lettura comparabile; altrimenti si rivaluta la (c) |
| B2′ | query di regione (1 kb, 10 kb, 1 Mb): byte letti e latenza, gruppi P e P+S | ≤ CRAM+CRAI per P+S |
| B7 | variazione dei parametri: slice 5k/10k/25k × span 5/10/16 | fissa i default |

La B3 si fa con il prototipo Swift della fase X1 (§10), senza la spec definitiva.

---

## 9. Regole brevettuali applicate

Rischio accettato dal proprietario il 23/10/2026; le regole dello studio §3.3 restano obbligatorie. Per ogni rivendicazione indipendente (studio §3.1), l'elemento che XIG **non** ha:

| Brevetto | Elemento richiesto dalla rivendicazione | In XIG |
|---|---|---|
| EP3526711B1, EP3526709B1 | classificazione delle letture in classi per tipo di mismatch, descrittori per classe, master index per classe | **nessuna classificazione**: tutti i record di una slice, mappati o no, perfetti o con indel, sono in un'unica sequenza in ordine di coordinata, con le stesse serie (regola 1) |
| US11763918B2, EP3526706B1 | indice separato con start/end per unità **e** soglia MaxD nell'header che decide la collocazione delle coppie | **nessun MaxD** né equivalente; i mate sono sempre "detached" (`MF`, `NS`, `NP`, `TS` per record), mai raggruppati per distanza; selezione per sovrapposizione standard (regola 2). L'indice separato da solo è CRAI/BAI |
| US11404143B2 | non mappate raggruppate in cluster per signature | non mappate in coda, nell'ordine d'ingresso; nessun clustering (regola 3) |
| US11386979B2 | unità di porzioni di riferimento con posizione assoluta, insieme a unità di letture classificate | riferimento esterno o FASTA intero per digest; nessun segmento di riferimento nell'insieme (regola 4) |
| EP3652862B1 / US10938415B2 | codebook di quantizzazione delle qualità scelti per locus | qualità lossless con fqzcomp (regola 5) |
| EP3311318B1 | consenso costruito dalle letture precedenti | nessun consenso: differenze solo rispetto al riferimento esterno |
| EP3526712B1 | lista dei dataset e tabella di mappatura dataset→stream in un multiplex | catalogo di file generico XIZ; da sottoporre al consulente se mai si chiede un parere |
| US20200051665A1 (pendente) | linguaggio ampio su "classes … blocks of descriptors" | da monitorare; la difesa è la genealogia (sotto) |

**Il punto di contatto più vicino** resta lo schema "unità per regione + flussi per campo + indice separato", che è proprio dell'opzione (b): è il motivo del rischio accettato. La genealogia da documentare nella spec, con date:
- CRAM 1.0 (Hsi-Yang Fritz et al., 2011): flussi per campo, riferimento esterno;
- CRAM 2.0–3.0 (2013–2014): data series in blocchi esterni con codec per blocco; CRAI con start/span per slice;
- Goby (Campagne et al., 2012–2013): allineamenti in formato colonnare;
- Parquet (2013) e ADAM (Massie et al., 2013): row group e column chunk;
- BAI e tabix (Li, 2011): indice di regione separato.

---

## 10. Piano

| Fase | Contenuto | Uscita | g [stima] |
|---|---|---|---|
| **X1 Prototipo e B3** | serie e span in Swift, codec htscodecs per frame, writer e reader minimi (senza XGI paginato), round trip con `record_digest` | numeri B3/B7, decisione sui default | 10–15 |
| **X2 Spec XIZ 1.3 XIG** | §4–6 di questo documento in forma normativa in `XIZ_SPEC.md` (§13), con la genealogia del §9 | spec | 4–6 |
| **X3 Xipper completo** | XGI paginato, query di regione, export, cifratura, app/CLI/MCP, fuzz, interop samtools | Xipper 3.x archivia e interroga XIG | 18–25 |
| **X4 libxiz (C)** | core XIZ (studio §4) + decoder XIG + plugin hFILE che presenta l'insieme come **BAM virtuale** (BGZF livello 0 generato al volo, BAI dall'XGI): samtools, bcftools e pysam leggono senza modifiche | `samtools view xiz://…` | 45–65 |
| **X5 Java e Python** | lettori puri del core + decoder XIG (htscodecs va reimplementato o legato: rANS e aritmetico sono piccoli; fqzcomp e tok3 no. Opzione: JNI/cffi solo per i codec) | JAR e wheel | 40–60 |
| **Trasversale** | vettori di conformità (anche XIG), benchmark | suite | 10–14 |

Totale fino a X3, cioè XIG in Xipper: **32–46 g**. Con le librerie: **127–185 g**.

---

## 11. Domande ancora aperte

1. **Estensione**: `.xiz` per tutto (proposta), oppure `.xig` per gli archivi che contengono insiemi di allineamenti?
2. **Codec in Java e Python** (X5): reimplementare fqzcomp e tok3 in puro Java/Python (lento, molto lavoro) o legare htscodecs via JNI/cffi (wheel e JAR per piattaforma)? Proposta: binding nativo solo per i codec, il resto puro.
3. **FASTQ** non allineati: entrano in XIG (stesse serie Q e N, senza P/M/F, basi in `BA` con aritmetico)? Senza clustering (regola 3) il guadagno su zstd/BGZF è soprattutto da fqzcomp e tok3.
4. **Parametri di default**: slice 10k e span 10 sono il punto di partenza; B7 li fissa.
5. **Consulente brevettuale**: il rischio è accettato; resta utile un parere su EP3526712 e sulla domanda pendente US20200051665 prima di pubblicare la spec?

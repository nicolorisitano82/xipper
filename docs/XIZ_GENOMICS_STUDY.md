# XIZ per la genomica e lettori in C, Java e Python: studio di progetto

*Studio del 23/10/2026. Basi: [XIZ_SPEC.md](XIZ_SPEC.md) (formato 1.2), [MPEGG_STUDY.md](MPEGG_STUDY.md), [STUDIO.md §4.4–4.6](../STUDIO.md), [rapporto sul formato](reports/Nuovo%20formato%20di%20compressione%20Xipper.md). Qui non si ripetono.*

> **Brevetti.** Il §3 è un'analisi tecnica delle rivendicazioni pubbliche. **Non è un parere legale.** Prima di rilasciare un writer "XIZ genomico" serve il parere di un consulente brevettuale (passo P0 del §5).

> **Aggiornamento del 23/10/2026: decisione presa.** Il titolare ha scelto l'**opzione (b)**, il profilo nativo, chiamato **XIG**, invece della (c) raccomandata qui, e ha **accettato il rischio brevettuale** relativo: il passo P0 non è più un prerequisito, resta un'opzione (domanda 5 del disegno). Le regole del §3.3 restano obbligatorie. Il disegno è in [XIG_DESIGN.md](XIG_DESIGN.md); il piano diventa quello del suo §10 (X1 prototipo e benchmark B3 come soglia, poi spec, Xipper, libxiz, Java e Python). Il resto di questo studio è l'analisi che ha portato alla scelta e resta com'era.

Convenzioni:
- **[V]**: numero letto alla fonte linkata.
- **[S]**: numero preso da un riassunto della fonte, non dal testo completo.
- **[stima]**: valore dedotto qui, da misurare.
- g = giorni-persona.

---

## 0. Sintesi

- **Cosa serve davvero in genomica.** Le operazioni che contano sono quattro:
  - la query per regione (`chr:start-end`) su letture allineate e varianti;
  - la lettura di una sola colonna (qualità, nomi, genotipi);
  - un riferimento identificato per digest (MD5/refget);
  - la lettura remota a intervalli di byte (htsget, S3).

  CRAM+CRAI e BGZF+tabix/CSI coprono già bene la prima e la terza. Le colonne sono il punto forte dei formati colonnari per varianti: Zarr, GDS, pgen e SAV sono da 3 a 10 volte più compatti di BCF e da 100 a 300 volte più veloci sui calcoli per colonna. Per le letture allineate nessun formato aperto fa meglio di CRAM 3.1 di più del 10–20%, salvo Genozip, che è commerciale.
- **XIZ 1.2 ha già metà dei mattoni:**
  - frame indipendenti con indice nel catalogo;
  - AEAD per frame;
  - dedup di file interi e di chunk CDC;
  - catalogo TLV estendibile con tag non critici;
  - catena di footer.

  **Mancano tre cose:**
  - un **indice di regione**;
  - **frame allineati** alle unità genomiche: oggi un frame da 4 MiB taglia i container CRAM e i blocchi BGZF a caso;
  - la **lettura parziale** di un frame `store`.
- **Le tre opzioni:**

  | Opzione | Cosa fa | Pro | Contro |
  |---|---|---|---|
  | (a) "contenitore" | CRAM/BCF/BGZF così come sono, più un indice XIZ | costa poco ed è byte-esatto | non comprime di più e le colonne restano legate al formato interno |
  | (b) profilo nativo | record raggruppati per regione e uno stream per campo, codec htscodecs come codec di frame | il guadagno più alto, ma solo stimato: dal 5 al 10% su CRAM 3.1 | **è il più vicino ai brevetti MPEG-G** e richiede un decoder di record nuovo **in tre linguaggi** |
  | (c) ibrido "CRAM-in-XIZ" | il payload resta CRAM 3.1 standard; frame allineati alle slice e ai gruppi di data series; indice di regione e mappa dei blocchi nel catalogo; VCF/BCF come in (a) o con un indice nativo sul contenuto | rapporto pari a CRAM 3.1; export byte-esatto; lettura di gruppi di colonne; decoder di record già esistenti (htslib, htsjdk, pysam); prior art solida (CRAM 2012–2014) | non va oltre CRAM sul rapporto |

- **Raccomandazione: (c).** È un profilo "XIZ 1.3 genomico" fatto quasi solo di **tag non critici e di un bit opzionale**: un lettore 1.2 estrae ancora tutto.
  - (b) si rinvia: va riconsiderato solo se i benchmark mostrano più del 10% di guadagno **e** se il parere brevettuale lo consente.
  - Le varianti in forma colonnare (stile Zarr/GDS) sono una fase successiva separata.
- **Lettori:**
  - **`libxiz` in C11** come implementazione di riferimento, con un **plugin hFILE per htslib**, così `samtools`/`bcftools`/pysam leggono `xiz://archivio.xiz#campione.cram` con le loro query di regione;
  - **lettore Java puro**, cioè JCE, aircompressor o zstd-jni e Bouncy Castle, con un adattatore `SeekableStream` per htsjdk;
  - **lettore Python puro** con `zstandard`, `cryptography` e `argon2-cffi`;
  - una sola suite di conformità con vettori condivisi.
  - Impegno totale stimato: **circa 85–125 g** per l'intero piano, di cui circa 65–90 g per le librerie e la conformità.

---

## 1. Cosa chiede la genomica a un contenitore d'archivio

### 1.1 Operazioni e requisiti

| Operazione | Esempio | Requisito sul formato |
|---|---|---|
| **Query di regione su letture** | IGV, `samtools view x.cram chr7:55.0M-55.3M` | unità piccole e ordinate per coordinata, un indice da regione a byte, decodifica solo delle unità toccate |
| **Query di regione su varianti** | `bcftools view -r`, tabix | blocchi da 64 KiB, indice a bin + lineare con finestre da 16 kb ([Li 2011](https://academic.oup.com/bioinformatics/article/27/5/718/262743), [tabix spec](https://samtools.github.io/hts-specs/tabix.pdf)) [V] |
| **Accesso a una colonna** | solo POS, `flagstat` senza qualità, frequenze alleliche, solo GT | campi in stream separati, che si possano leggere senza toccare gli altri |
| **Riferimento** | decodifica CRAM; verifica | sequenze identificate per **MD5** (`@SQ M5`) o per **digest GA4GH** `SQ.` + sha512t24u ([refget v2](https://samtools.github.io/hts-specs/refget.html)) [V]; una copia sola per coorte |
| **Integrità** | trasferimenti di BAM da 100 GB | checksum per blocco e marker di fine (BGZF EOF, container EOF di CRAM); un digest del file |
| **Cifratura** | dati clinici, GDPR | cifratura autenticata che lasci **l'accesso casuale** (Crypt4GH lo fa a segmenti da 64 KiB; in Xipper è esclusa, STUDIO §4.6) |
| **Accesso remoto** | S3, htsget, DRS | poche richieste `Range` per query; htsget restituisce un "ticket" con URL e header `Range` che il client concatena ([htsget](https://samtools.github.io/hts-specs/htsget.html)) [V] |
| **Ritorno ai formati standard** | pipeline GATK/DeepVariant | export in BAM/CRAM/VCF senza perdite, possibilmente byte-esatto |

### 1.2 Formati esistenti: unità di accesso, indice e numeri

| Formato | Unità di accesso | Colonne separate | Indice | Numeri (dataset) |
|---|---|---|---|---|
| **BAM + BAI/CSI** | blocco BGZF ≤ 64 KiB | no, record a righe | bin + lineare, 16 kb | NovaSeq, 10M letture: 515 MB, decodifica in 0,8 s ([htslib](https://www.htslib.org/benchmarks/CRAM.html)) [V] |
| **CRAM 3.1 + CRAI** | **slice** (default 10.000 record; profili small/archive 25k/100k) | sì: ogni data series in un blocco esterno con il suo codec; htslib può saltare i campi non richiesti | CRAI: una riga per slice (ref, start, span, offset del container, landmark, dimensione) ([CRAMv3](https://samtools.github.io/hts-specs/CRAMv3.pdf)) [V] | NovaSeq, 10M: 176 MB in 1,9 s (normal), 158 MB in 5,8 s (archive); HG002 2×250: 1546 → 852 MB ([htslib](https://www.htslib.org/benchmarks/CRAM.html)) [V]. Dal 50 al 70% più piccolo di BAM, dal 7 al 15% più piccolo di CRAM 3.0 ([Bonfield 2022](https://doi.org/10.1093/bioinformatics/btac010)) [V] |
| **VCF.gz + tbi/csi** | blocco BGZF | no | tabix | 1000G fase 3: 14,4 GB; GT a 18,6 M/s ([Zheng 2017](https://academic.oup.com/bioinformatics/article/33/15/2251/3072873)) [V] |
| **BCF + CSI** | blocco BGZF | no (record binari) | CSI | 1000G fase 3: 12,3 GB; GT a 213,5 M/s ([Zheng 2017](https://academic.oup.com/bioinformatics/article/33/15/2251/3072873)) [V] |
| **MPEG-G** (23092) | **access unit** (AU) per classe P/N/M/I/HM/U; blocco per descrittore | sì: descriptor stream, anche concatenati tra AU | master index table [sequenza][classe][AU] con start/end e offset ([Alberti 2018](https://doi.org/10.1101/426353)) [S] | Genie-Ref: di poco meglio di CRAM 3.1, mediana su 23 file; CABAC oltre l'80% del tempo ([Müntefering 2024](https://doi.org/10.1038/s42003-024-06249-8)) [V]; in lettura circa 20 volte più lento di CRAM (MPEGG_STUDY §0) |
| **Zarr / VCF Zarr** (sgkit, bio2zarr) | chunk di varianti × campioni (default 10.000 × 1.000) | **sì**, un array per campo | coordinate in array ordinati | 10⁶ campioni simulati: 23,75 GiB contro 21,25 GiB di SAV; af-dist in 7,3 h contro 20,6 h di bcftools. GEL chr2: 12,81 TiB di VCF diventano 2,54 TiB; af-dist 309 volte più veloce ([Czech 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12127038/)) [V] |
| **SeqArray / GDS** | blocchi per variabile | sì | per variante | 1000G: 2,6 GB (lzma); GT a 629–760 M/s; AF in 6,65 min contro 125 min di vcftools su BCF ([Zheng 2017](https://academic.oup.com/bioinformatics/article/33/15/2251/3072873)) [V] |
| **SAV** (Savvy) | blocchi zstd, sparse | parziale | s1r | 200k campioni: SAV 4,36 GiB contro BCF 25,13 GiB; deserializzazione in 1,73 contro 596,7 min ([LeFaive 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC9502232/)) [V] |
| **PLINK 2 pgen** | record di variante, indice a blocchi di 2¹⁶ | solo genotipi (più dosaggi) | per variante | dal 39 al 67% di BCF (2k–200k campioni) ([LeFaive 2021](https://pmc.ncbi.nlm.nih.gov/articles/PMC9502232/)) [V]; [spec](https://github.com/chrchang/plink-ng/blob/master/pgen_spec/pgen_spec.tex) |
| **TileDB-VCF** | tile di array sparso | sì | ancore (gap di 1.000 bp) | 1000G chr22 × 12.808 campioni: 9,41 GiB contro 5,09 GiB di VCF.gz; decine di GiB di RAM ([Hafidi, PVLDB 2025](https://www.vldb.org/pvldb/vol18/p4045-hafidi.pdf)) [V] |
| **Hail MatrixTable / VDS** | partizioni Spark | sì (righe/colonne/entry) | per partizione | VDS: circa 260 MiB per genoma; cresce in modo lineare, mentre il pVCF cresce più che linearmente ([Poterba 2024](https://doi.org/10.1101/2024.01.09.574205)) [V] |
| **Parquet** (ADAM, Glow, vcf2parquet) | row group / column chunk | sì | statistiche min/max | letture NA12878 60x: ADAM circa il 20% più piccolo di BAM, CRAM circa il 43% ([ADAM](https://adam.readthedocs.io/en/latest/benchmarks/storage/)) [V]; non si è trovato un benchmark pubblicato Parquet contro BCF; "GeneticsPar" non risulta esistere |
| **Genozip** | blocchi "vblock" | sì | sì | da 1,1 a 2,5 volte meglio di CRAM 3.1, ma decomprime più lento di CRAM in 22 casi su 28 (preprint degli autori, [bioRxiv 2022](https://doi.org/10.1101/2022.09.12.507582)) [V]; commerciale |

### 1.3 Cosa se ne ricava

1. **Per le letture allineate il riferimento da battere è CRAM 3.1.** Per lo stesso compromesso tra granularità e codec, il margine dei formati aperti è piccolo:
   - CRAM normal → archive: −10% (176 → 158 MB);
   - Genie-Ref su CRAM 3.1: "di poco".

   Un formato nuovo per gli allineamenti può valere solo per **funzioni** (cifratura per frame, dedup del riferimento, accesso remoto unificato, gruppi di colonne), non per il rapporto.
2. **Per le varianti il guadagno vero è colonnare**, dalle 3 alle 6 volte rispetto a BCF, e dalle 100 alle 300 volte sui calcoli per colonna. BCF e VCF.gz sono formati a righe. Lì un profilo nativo colonnare XIZ avrebbe senso; la prior art (GDS 2012–2017, PLINK, BGT, Zarr) è ampia e lontana dalle rivendicazioni MPEG-G, che riguardano le letture.
3. **La granularità dell'accesso decide il costo di una query.** Esempio su un 30x NovaSeq [stima]:

   | Formato | Unità | Copertura | Byte per una regione da 10 kb |
   |---|---|---|---|
   | BAI | blocco BGZF | ~2.000 letture | ~200–300 KB |
   | CRAM, slice da 10k | slice | ~50 kb | ~250 KB |
   | CRAM, slice da 100k | slice | ~500 kb | ~2,4 MB |

   Il tempo di decodifica resta nei millisecondi in tutti e tre i casi: 0,19 µs per record in CRAM 3.1 normal, dai 10M record in 1,9 s di htslib.
4. **"Lettura senza decompressione" va inteso così:** si decodifica solo ciò che la query tocca, con un costo O(query) e non O(file). Nessun formato risponde senza decodificare i blocchi toccati.

---

## 2. Opzioni di progetto per "XIZ genomico"

### 2.0 Da dove si parte: XIZ 1.2 contro le esigenze

| Esigenza | XIZ 1.2 oggi | Cosa manca |
|---|---|---|
| Accesso casuale | frame indipendenti, catalogo con offset, CRC e dimensioni di ogni frame; il caso peggiore è decodificare un frame da 4 MiB | i frame sono **ciechi** rispetto al contenuto: un container CRAM o un blocco BGZF può stare a cavallo di due frame |
| Indice per contenuto | nessuno: solo da file a extent | un **indice di regione** (che non serve a estrarre, quindi può essere un tag non critico) |
| Lettura parziale | non prevista: §8 punto 7 legge, verifica e decomprime frame interi | per i frame `store` non cifrati: leggere un sottointervallo (l'integrità è garantita dal CRC32 per blocco di CRAM o di BGZF) |
| Cifratura | AES-GCM per frame, con l'indice del frame nel nonce e nell'AAD; catalogo in STREAM | niente per il formato. **Però** il tag copre tutto il frame, quindi una query cifrata scarica e verifica frame interi: la granularità dei frame diventa la granularità della query |
| Dedup | file interi + FastCDC, con chiave quando l'archivio è cifrato | su CRAM e BGZF compressi il CDC non trova nulla (sono dati già entropici); il guadagno vero è **un riferimento FASTA per coorte** |
| Estendibilità | tag TLV (bit 15 = critico), bit di funzione obbligatori e opzionali, `version_minor` | — |
| Codec | `codec` u8: 0 store, 1 zstd | per (b): valori nuovi, con un bit obbligatorio |
| Catalogo | letto per intero all'apertura, con SHA-256 su tutto, fino a 1 GiB | un 30x WGS con frame da circa 120 KB ha circa 130.000 frame, cioè un catalogo di circa 3 MB [stima]; si può fare, ma l'indice di regione va **fuori** dal catalogo |

### 2.1 Opzione (a): CRAM/BCF/BGZF così come sono, più un indice a livello XIZ

**Scrittura.** Il file genomico entra come entry normale con codec `store` (Xipper oggi fa già lo smart-store). Il writer **taglia i frame sui confini naturali**:
- per CRAM, gruppi di container;
- per BGZF, gruppi di blocchi;

con un obiettivo di 256 KiB–1 MiB per frame. L'indice nativo (`.crai`/`.bai`/`.csi`/`.tbi`) viene archiviato accanto, come entry.

**Query.** Il lettore apre l'indice nativo e ottiene gli offset nel file interno. La conversione in posizioni XIZ è diretta:
- CRAI dà offset di byte;
- BAI/CSI/TBI danno virtual offset, cioè `coffset` = offset di byte di un blocco BGZF.

Gli extent traducono un offset dell'entry in (frame, offset nel frame). In un frame `store` i byte coincidono con il file originale.

| Criterio | Valutazione |
|---|---|
| Cosa si decodifica per una regione | l'indice nativo (piccolo), poi gli stessi byte che leggerebbe htslib, più l'intero frame se l'archivio è cifrato |
| Una sola colonna | come il formato interno: CRAM sì, a livello di blocco ma dentro la slice; BCF/VCF no |
| Rapporto | quello del formato interno; overhead XIZ: 32 + 24 (+16 se cifrato) byte per frame, cioè lo 0,01–0,03% con frame da 256 KiB [stima] |
| Velocità | scrittura limitata dal disco (store); lettura uguale a CRAM/BGZF |
| Dedup | solo file identici e riferimento FASTA condiviso |
| Cifratura | ✅ per frame; con frame allineati, una query decifra 1–4 frame |
| Export | **byte-esatto**: è il file originale |
| Formato | **nessuna modifica obbligatoria**; tag non critici facoltativi (§2.4) |
| Prior art | BGZF/tabix (2011), CRAM/CRAI, zstd seekable, ZIP store |

**Variante (a′): ricompressione del contenuto BGZF.** Il contenuto decompresso di BAM, VCF o BCF va in frame zstd, con un indice CSI calcolato sugli **offset del contenuto** invece che sui virtual offset.
- Guadagno: zstd -19 su VCF testuale e su BAM rispetto a deflate da 64 KiB [stima: dal 15 al 35%, da misurare].
- Costo: l'export ricrea un BGZF **equivalente nel contenuto, non byte-identico** all'originale, perché la ricostruzione di deflate non è garantita.
- Va bene come "importa", non come "archivia". Per BAM conviene comunque CRAM.

### 2.2 Opzione (b): profilo nativo (record per regione e stream per campo)

**Scrittura.**
- I record allineati, ordinati per coordinata, si raggruppano in **blocchi di regione** di N record.
- Per ciascun blocco, ogni campo (posizioni in delta, flag, CIGAR/feature, basi diverse dal riferimento, qualità, nomi, tag) va in uno stream separato.
- Ogni stream diventa uno o più frame XIZ, con codec nuovi: `2` rANS Nx16, `3` arith adattivo, `4` fqzcomp_qual, `5` name tokenizer 3, `1` zstd. Sono quelli di htscodecs, già vendorizzati in `Vendor/htscodecs`.
- Un indice di regione nel catalogo, o in frame indice, completa il tutto.

**Il vantaggio rispetto a CRAM** è **separare la granularità d'accesso da quella di compressione**:
- i campi "caldi" (posizione, flag, CIGAR) in blocchi piccoli;
- quelli "freddi" e voluminosi (qualità, nomi) in blocchi grandi, dove fqzcomp e il tokenizer rendono di più.

Il passaggio da slice da 10k a slice da 100k vale il −10% in CRAM ([htslib](https://www.htslib.org/benchmarks/CRAM.html)); qui lo si otterrebbe senza peggiorare la query delle posizioni.

| Criterio | Valutazione |
|---|---|
| Cosa si decodifica per una regione | indice → blocchi → frame dei campi richiesti; per la sola posizione, pochi KB |
| Una sola colonna | ✅ il miglior caso possibile: un frame per campo |
| Rapporto | CRAM 3.1 normal con un margine dal −5 al −10% [stima, dai dati 10k→100k di htslib]; dal 30 al 55% di BAM |
| Velocità | scrittura come l'encoder CRAM di Xipper; lettura con i codec di htscodecs (rANS fino a circa 2 GB/s in decodifica, fqzcomp circa 27 MB/s [V, Bonfield 2022]) |
| Dedup | come (a); nessun guadagno da CDC |
| Cifratura | ✅, e protegge per campo (si possono cifrare solo nomi e qualità; un'opzione, non un requisito) |
| Export | transcodifica verso BAM/CRAM: **non byte-esatta** rispetto a un CRAM d'origine, solo equivalente nei record |
| Formato | bit obbligatorio nuovo (`genomic_codecs`) più codec 2–5; un lettore 1.2 rifiuta l'archivio |
| **Costo nascosto** | un **decoder di record nuovo in C, Java e Python** (record e CIGAR dal riferimento, mate, tag): circa 25–40 g per linguaggio [stima], senza htslib né htsjdk a cui appoggiarsi |
| Brevetti | **il più esposto** (§3): blocchi di regione con stream per descrittore e indice separato sono l'oggetto di US11763918 ed EP3526706, salvo il limite di MaxD |

### 2.3 Opzione (c): ibrido "CRAM-in-XIZ" (raccomandato)

**Idea.** Il codec dei record resta **CRAM 3.1 standard** (GA4GH, prior art dal 2011 al 2014). XIZ aggiunge ciò che CRAM non ha:
- frame allineati e cifrati;
- un indice di regione e la mappa dei blocchi, nello spazio dell'archivio;
- un riferimento deduplicato per coorte, identificato per digest;
- l'accesso remoto uniforme per tutti i file dell'archivio.

**Scrittura** (Xipper, da `CRAMFileReader` e dal writer CRAI esistenti):
1. L'entry `x.cram` si archivia come `store`. Frame = **una slice**, oppure una slice divisa in **gruppi di blocchi esterni**:
   - G0: header di container, compressione e slice, core, e le data series di posizione, flag e lunghezze (`BF CF RI RL AP RG MF NS NP TS NF TL MQ`);
   - G1: feature e basi (`FN FC FP DL BB BA BS IN RS PD HC SC`);
   - G2: `QS`, `QQ`;
   - G3: `RN`;
   - G4: tag.

   I blocchi CRAM di un gruppo non sono contigui nel file. Il frame allora contiene **i blocchi del gruppo nell'ordine del file**, e gli extent dell'entry ricompongono l'ordine originale: l'entry resta **il file CRAM byte per byte**.
2. Una **mappa dei blocchi** per slice: content id → (frame, offset, lunghezza).
3. Un **indice di regione** XGI (§2.4), per slice: ref, start, end, numero di record, frame dei gruppi.
4. I **riferimenti**, cioè `@SQ` con nome, lunghezza, M5 e il digest GA4GH, dentro un tag. Se l'utente lo archivia, il FASTA va come entry deduplicata (una copia per tutta la coorte).

**Query di regione:**
1. dall'XGI alle slice toccate;
2. si leggono G0 (e G1 se servono le basi) di quelle slice;
3. il decoder CRAM (htslib, htsjdk o Swift) decodifica la slice con i soli blocchi presenti.

Su htslib si chiede solo dei campi tramite `CRAM_OPT_REQUIRED_FIELDS` (`samtools view --input-fmt-option required_fields=…`). Che htslib tolleri blocchi **assenti** e non solo "non decodificati" **va verificato**: se non li tollera, `libxiz` passa blocchi vuoti con lo stesso content id.

**Senza codice nuovo:** il plugin hFILE (§4) espone l'entry come file CRAM virtuale. htslib legge il CRAI (o l'XGI convertito in CRAI al volo) e ottiene le stesse slice, scaricando però tutti i gruppi.

| Criterio | Valutazione |
|---|---|
| Cosa si decodifica per una regione | indice XGI (paginato) → 1–2 slice → solo i gruppi richiesti. Con slice da 25k di un 30x: circa 600 KB per slice, che scendono a circa 150–250 KB se si leggono solo G0+G1 [stima] |
| Una sola colonna | ✅ a livello di gruppo (per esempio tutte le qualità, `flagstat` senza QS e RN); più grossolano di (b) |
| Rapporto | **uguale a CRAM 3.1** del profilo scelto (normal/small/archive), più lo 0,05% di overhead [stima]. Contro BAM: 34% (NovaSeq) e 55% (HG002 2×250) in normal [V, htslib] |
| Velocità di scrittura | un CRAM esistente si importa a velocità di disco (parsing di header e slice, nessuna decodifica); BAM→CRAM con l'encoder esistente |
| Velocità di lettura | quella di CRAM 3.1 (normal: 1,9 s per 10M record in htslib); più l'AES-GCM, che non pesa (GB/s su Apple Silicon, rapporto §AEAD) |
| Dedup | FASTA una volta per archivio; CRAM identici una volta; il CDC va spento sulle entry CRAM (già si fa) |
| Cifratura | ✅ per gruppo: un'interrogazione su posizioni e flag non scarica né decifra qualità e nomi |
| Export | **byte-esatto** (`xipper extract`); i `.crai` si rigenerano dall'XGI |
| Formato | tag non critici e un bit **opzionale**; un lettore 1.2 estrae il CRAM normalmente |
| Brevetti | il payload è CRAM; l'indice XIZ indicizza slice CRAM con intervalli di sovrapposizione, come CRAI (§3) |

**Varianti nell'ibrido:**
- VCF.gz e BCF come (a), con frame allineati a gruppi di blocchi BGZF e `.tbi`/`.csi` convertiti in XGI;
- (a′) a richiesta.

Le colonne sulle varianti si ottengono solo con un **profilo colonnare separato** (§5, fase 4), modellato su Zarr/GDS/pgen.

### 2.4 Proposta concreta: XIZ 1.3, profilo genomico

| Elemento | Proposta | Compatibilità |
|---|---|---|
| `optional_features` bit 1 `genomic` | l'archivio contiene indici XGI e tag genomici | un lettore 1.2 lo ignora |
| `version_minor` | 3, solo se è presente anche una funzione obbligatoria nuova; per il solo profilo (c) resta quello delle funzioni usate | — |
| Tag `0x0009 media` (non critico) | `u8 kind` (1 CRAM, 2 BAM, 3 VCF.gz, 4 BCF, 5 FASTA, 6 FASTQ.gz) · `u8 major` · `u8 minor` · `u8 flags` (bit 0 = frame allineati) | ignorato |
| Tag `0x000A region_index` (non critico) | `u8 format` (1 = XGI v1) · n × (`frame u32`, `offset u32`, `length u32`): extent del blob XGI nei frame di dati, **senza un'entry propria** | ignorato. I byte restano dati non referenziati, cosa che XIZ 1.1 già ammette dopo un append. Nell'archivio cifrato l'indice è protetto dall'AEAD del frame |
| Tag `0x000B references` (non critico) | n × (`name`, `u64 length`, `md5[16]`, `sha512t24u[24]`, `u32 entry_index` o `0xFFFFFFFF`) | ignorato |
| Tag `0x000C block_map` (non critico) | per CRAM, per slice: n × (`content_id i32`, `group u8`); i frame di ogni gruppo stanno nell'XGI | ignorato |
| Regola nuova, §4.2 bis | "un lettore **può** leggere un sottointervallo del payload di un frame `store` non cifrato; in quel caso non verifica il CRC del frame e **deve** verificare l'integrità del formato interno, cioè il CRC32 dei blocchi CRAM o di BGZF" | per i lettori esistenti non cambia niente |
| Raccomandazione per i writer | frame allineati: CRAM, 1 slice o 1 gruppo per frame; BGZF, frame di 256 KiB–1 MiB su confini di blocco | — |
| Solo per (b) | `required_features` bit 3 `genomic_codecs`: codec 2–5. Un lettore 1.2 rifiuta l'archivio | rottura voluta |

**XGI v1** (blob compresso con zstd):

```
magic "XGI1" · u32 n_refs · per ref: name, u64 length
u32 n_pages · per pagina: ref_id u32, start u64, max_end u64, n_items u32, extent (frame,offset,len)
pagina = n_items × (ref_id i32, start u64, end u64, n_records u32,
                    first_frame u32, group_mask u8, slice_offset_in_entry u64)
```

- La sovrapposizione si calcola come in CRAI: `start ≤ e && end ≥ s`. Su ogni pagina c'è un `max_end` cumulativo per la ricerca binaria.
- La pagina di primo livello è piccola (circa 1 KB per 1.000 pagine) e permette una query remota con 2 richieste: pagina, poi frame.
- **Nessun parametro di distanza tra coppie e nessuna classificazione delle letture**: vedi il §3.

**Riferimento:**
1. per ogni `@SQ`, il lettore cerca prima un'entry FASTA dell'archivio con lo stesso MD5;
2. poi la cache locale (`REF_PATH`/`REF_CACHE` di htslib);
3. poi refget, solo con opt-in e un URL dell'utente (STUDIO §4.6: niente rete di default).

**Privacy nell'archivio cifrato.** Numero e dimensioni dei frame restano visibili (spec §6.5). Con frame per slice a numero fisso di record, le dimensioni rivelano la compressibilità di ogni slice, non le coordinate, perché l'indice è cifrato. È un'informazione debole; un'opzione di padding dei frame a classi di dimensione la elimina, al costo del 2–5% [stima].

### 2.5 Confronto

| | (a) contenitore | (b) nativo | (c) CRAM-in-XIZ |
|---|---|---|---|
| Rapporto contro CRAM 3.1 | = (CRAM); BGZF invariato | dal −5 al −10% [stima] | = |
| Rapporto contro BAM | = BAM se l'input è BAM | dal 30 al 50% | 34–55% |
| Regione: byte letti | come l'indice nativo (+ frame interi se cifrato) | minimo | slice, solo i gruppi richiesti |
| Colonna | no (CRAM sì ma per slice) | per campo | per gruppo |
| Export | byte-esatto | equivalente | byte-esatto |
| Modifiche al formato | nessuna obbligatoria | bit obbligatorio, 4 codec | solo opzionali |
| Codice nuovo in Swift | 5–8 g | 30–45 g | 12–18 g |
| Decoder di record in C/Java/Python | htslib/htsjdk/pysam | **da scrivere: 75–120 g** | htslib/htsjdk/pysam |
| Rischio brevettuale (§3) | basso | **medio-alto** | basso |

---

## 3. Brevetti: cosa evitare e quale prior art seguire

> Analisi tecnica delle rivendicazioni indipendenti pubblicate su Google Patents (testo verbatim salvato nello scratchpad della sessione). Le date di scadenza sono stime di Google. **Non è un parere legale:** la portata di una rivendicazione dipende dall'interpretazione, dalla giurisdizione e dalle rivendicazioni dipendenti, e qui non si valuta la validità. Il proprietario ha accettato il rischio solo per la **lettura** di MPEG-G; un **writer** XIZ ispirato a MPEG-G è un'altra questione e richiede il passo P0 (§5).

### 3.1 Rivendicazioni indipendenti, in breve

| Brevetto | Titolare (Google Patents) | Scadenza stimata | Cosa richiede la rivendicazione indipendente (tutti gli elementi insieme) |
|---|---|---|---|
| [EP3526711B1](https://patents.google.com/patent/EP3526711B1/en) | GenomSys | 2036-10 | allineare e **classificare le letture in 5 classi secondo il tipo di mismatch** (nessuno / solo N / sostituzioni / indel e clip / non mappate); **insiemi di descrittori specifici per classe**; "layer" omogenei con un modello e un entropy coder per layer |
| [US11404143B2](https://patents.google.com/patent/US11404143B2/en) | Philips (cessione registrata il 7/11/2025) | 2038-03 | **letture non mappate raggruppate in cluster per una "signature"** (sottosequenza comune, con tolleranza di mismatch), codificate in blocchi con header, cioè in access unit; il decoder distingue le AU per tipo di mappatura |
| [US11386979B2](https://patents.google.com/patent/US11386979B2/en) | Philips | 2037-12 | unità di dati di **tipo 1 = porzioni di riferimento** con la posizione assoluta, più unità di **tipo 2 = letture classificate**, con le posizioni delle letture *perfettamente corrispondenti* al segmento, prima posizione assoluta e poi delta in un layer, reverse complement in un altro layer |
| [US11763918B2](https://patents.google.com/patent/US11763918B2/en) | Philips | 2040-08 | accesso selettivo: start s_i ed end e_i di ogni AU in una **tabella d'indice codificata separatamente dalle AU** **e** una soglia **MaxD** (distanza massima tra le letture di una coppia) **nell'header del dataset**, che decide se la coppia si codifica come entità unica o separata. La dipendente 4 descrive i due layout ("descrittori diversi della stessa AU contigui" oppure "stesso descrittore tra AU contigue") |
| [EP3526706B1](https://patents.google.com/patent/EP3526706B1/en) | Philips | 2037-07 | come US11763918, più stretta: coppie entro MaxD nella stessa AU, oltre MaxD in AU diverse; decodifica delle AU con `s − MaxD ≤ s_i ≤ e` |
| [EP3526709B1](https://patents.google.com/patent/EP3526709B1/en) | GenomSys | 2036-10 | 4 classi con descrittori nominati (pos, pair, rcomp, rlen, nmis, snpt/snpp, indp/indt/indc) in layer e AU, più una **master index table con una sezione per classe** |
| [EP3526712B1](https://patents.google.com/patent/EP3526712B1/en) | GenomSys | — | trasmissione multiplexata: una **lista dei dataset genomici** e una **tabella di mappatura dataset→stream**, con AU ad accesso casuale fatte di layer di descrittori |
| [EP3311318B1](https://patents.google.com/patent/EP3311318B1/en) (LUH) | Leibniz Univ. Hannover | 2036-06 | differenza di ogni lettura rispetto a un **consenso per base costruito dalle letture precedenti** |
| [EP3652862B1](https://patents.google.com/patent/EP3652862B1/en) / [US10938415B2](https://patents.google.com/patent/US10938415B2/en) (LUH) | LUH | 2038-07 | quantizzazione delle qualità con **più codebook, scelti per locus** in base alle qualità delle letture che lo coprono |
| [US20200051665A1](https://patents.google.com/patent/US20200051665A1/en) | Philips, **domanda pendente** | — | 66 rivendicazioni con un linguaggio più ampio ("classes … blocks of descriptors"): **da seguire** |

### 3.2 Meccanismi proposti contro le rivendicazioni

| Meccanismo XIZ | Vicino a | Elemento che manca, se lo progettiamo così | Prior art su cui appoggiarsi |
|---|---|---|---|
| Payload CRAM 3.1, data series in blocchi esterni con il loro codec | EP3526711 ("layer" con un entropy coder per layer) | **nessuna classificazione delle letture per tipo di mismatch**: tutti i record di una slice sono nello stesso flusso, in ordine di coordinata | CRAM (Hsi-Yang Fritz 2011, [Genome Res.](https://genome.cshlp.org/content/21/5/734); CRAM 2.0 nel 2013 e 3.0 nel 2014, [Bonfield 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC8896640/)): "data series" per campo con un codec per blocco; Goby ([Campagne 2013](https://doi.org/10.1371/journal.pone.0079871), preprint [2012](https://arxiv.org/abs/1211.6664)) |
| Indice di regione XGI separato dai dati (start/end per slice) | US11763918 / EP3526706 | **nessun MaxD** nell'header e nessuna regola di collocazione delle coppie per distanza; mate sempre "detached" per record, come fa già `CRAMEncoder`; selezione per sovrapposizione standard (`start ≤ e ∧ end ≥ s`), non `s − MaxD ≤ s_i` | CRAI (una riga per slice con start e span), BAI/tabix ([Li 2011](https://academic.oup.com/bioinformatics/article/27/5/718/262743)), DeeZ con accesso casuale per regione ([Hach 2014](https://www.genomeweb.com/node/170036)) |
| Gruppi di colonne in frame separati | EP3526706, dipendente 4 (stesso descrittore tra AU contigue) | in (c) i gruppi restano **dentro la slice** (per una regione, i blocchi di slice diverse non vengono concatenati); la dipendente vale solo insieme alla rivendicazione 1 (MaxD) | file colonnari: ADAM/Parquet (Massie et al. 2013, [UCB/EECS-2013-207](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2013/EECS-2013-207.html)) [da verificare], Parquet (2013), GDS (2012) |
| Letture non mappate | US11404143 | **niente clustering per signature** (stile SPRING o global assembly): si conservano nell'ordine d'ingresso o del nome, come in CRAM | CRAM; le tecniche di bucketing esistevano prima del 2016 (SCALCE 2012, ORCOM 2014, Mince 2015), ma **non** si consiglia di usarle: non ne abbiamo bisogno |
| Riferimento | US11386979 | **niente unità di riferimento a segmenti** mischiate alle unità di letture: il riferimento è un'entry FASTA intera, identificata per MD5 e refget; niente "posizioni di letture perfettamente corrispondenti" per unità | `@SQ M5` di SAM/CRAM, refget |
| Qualità | EP3652862 | lossless di default (fqzcomp); se un giorno servisse la perdita: binning statico a 8 livelli in stile Illumina, **non codebook per locus** | binning Illumina, Crumble (Bonfield) |
| Consenso locale | EP3311318 | **non usarlo**: il riferimento è esterno; niente "local assembly" | DeeZ (2014) e samcomp (2013) sono anteriori, ma non servono |
| Più file in un archivio | EP3526712 (lista dei dataset + tabella di mappatura) | XIZ ha un catalogo di file, non un multiplex di stream "dataset→stream"; le entry sono file generici. È comunque la più generica: **da sottoporre al consulente** | ZIP/tar, il formato zstd seekable, gli archivi in generale |
| (b) nativo: blocchi di regione + stream per campo + indice | EP3526711/09 (se le letture si classificano), US11763918 (se c'è un MaxD), US20200051665 (pendente, ampia) | evitabile negli stessi modi, ma il disegno resta **vicino nella struttura**; il rischio di una rivendicazione futura più ampia (continuation) non si può misurare | CRAM + Parquet/Goby |

### 3.3 Regole di progetto (per stare sulla prior art)

1. **Mai classificare le letture** per numero o tipo di mismatch, né separarle in unità per classe. L'ordine è quello di coordinata, come in CRAM e BAM.
2. **Mai un parametro di distanza massima tra coppie** (o un suo equivalente) nell'header, né una regola che metta le coppie nella stessa unità secondo la distanza.
3. **Niente clustering o riordino** delle letture non mappate per sottosequenza.
4. **Il riferimento è un file intero** identificato per digest, non una serie di segmenti posizionati.
5. Qualità lossless, oppure binning statico.
6. **Il vocabolario della spec è quello di CRAM e degli archivi** (container, slice, data series, blocco, frame), non quello MPEG-G (access unit, descriptor, class, master index table, dataset group). Questo non cambia la portata delle rivendicazioni, ma evita ambiguità e mostra la derivazione dalla prior art.
7. **Documentare la genealogia** di ogni meccanismo (CRAM, CRAI, BGZF, zstd seekable, Parquet) nella spec, con date e link, come difesa di buona fede.

Contesto: J. Bonfield (autore di CRAM 3.x) contesta pubblicamente le domande GenomSys, che ritiene troppo ampie al punto da poter coprire CRAM, e quelle LUH, che ritiene anticipate da samcomp e Crumble ([“MPEG-G: the ugly”, 2018](http://datageekdom.blogspot.com/2018/09/mpeg-g-ugly.html); [discussione HN](https://news.ycombinator.com/item?id=18207478)). Contro EP3526711 non risulta presentata alcuna opposizione all'EPO. Da notare: la base di US11404143 e US11386979 è passata a Philips nel 2025 (Google Patents; per i brevetti EP la cessione non è verificata).

---

## 4. Librerie di lettura: C, Java, Python

### 4.1 Architettura

```
                    ┌────────────── conformance/ (vettori .xiz + risultati attesi JSON) ─────────────┐
libxiz (C11, MIT)   │ io: pread | mmap | callback range (HTTP/S3 fornito dall'utente)                 │
  core              │ superblock · keys (Argon2id) · HKDF · footer chain · catalog TLV · frame fetch  │
                    │ zstd (+dizionari) · AES-256-GCM · CRC32C · extent → pread dell'entry            │
  genomics (opz.)   │ XGI · references · block_map · query di regione → elenco di (frame, range)      │
  plugin            │ hfile_xiz.so per htslib: xiz://archivio.xiz#path/entry.cram                     │
                    └──────────────────────────────────────────────────────────────────────────────┘
Java  (puro)  : xiz-core (JCE AES-GCM, CRC32C del JDK, aircompressor | zstd-jni, BC Argon2)
                xiz-htsjdk (SeekableStream sull'entry, query XGI → CRAI)
Python (puro) : xiz (zstandard, cryptography, argon2-cffi) · xiz.htslib (plugin tramite pysam, se disponibile)
```

**Primitiva centrale: `pread` su un'entry.**
- Si traduce un intervallo dell'entry in extent.
- Si recuperano i frame, che per un `store` non cifrato possono essere anche parziali.
- Si verifica e si decifra, poi si decomprime **solo** ciò che serve, con una cache LRU dei frame.

Tutto il resto, compresi htslib, htsjdk e pysam, ci si appoggia sopra.

**Accesso remoto.** I passi sono:
1. una GET degli ultimi 64 KiB (footer, e spesso l'intero catalogo);
2. se il catalogo è più grande, una GET del catalogo;
3. se l'archivio è cifrato, una GET dei primi 4 KiB (superblock e keys);
4. per la query, una GET della pagina XGI;
5. una o più GET dei frame, unendo quelli adiacenti.

In totale sono **3–4 round trip a freddo**. Con circa 20–60 ms per GET su S3 nella stessa regione [stima], una query di regione costa da 100 a 250 ms a freddo e da 20 a 60 ms con l'indice in cache. CRAM via htslib su HTTP fa lo stesso numero di passi: CRAI, header, slice.

**XIZ come backend htsget.** Un server htsget può rispondere a una query su un CRAM dentro un `.xiz` **non cifrato** con un ticket di intervalli `Range` **direttamente sul file `.xiz`**:
- intervalli che saltano gli header di frame da 32 byte;
- più l'header SAM e il container EOF come `data:` URI.

Il client riceve un CRAM standard senza alcuna copia lato server. Con un archivio cifrato invece serve un server che decifri.

### 4.2 Scelte per linguaggio

| Linguaggio | Opzioni | Scelta | Motivo |
|---|---|---|---|
| **C** | OpenSSL/libcrypto per AES-GCM e SHA (Apache-2.0, pesante); **BearSSL** (MIT: AES-GCM costante nel tempo, SHA-256, HMAC); backend di piattaforma (CommonCrypto, BCrypt) | sottoinsieme di BearSSL vendorizzato come default, più un backend OpenSSL opzionale; zstd (BSD-3); Argon2 di riferimento (CC0/Apache-2.0, già in `Vendor/argon2`); CRC32C nostro (ARMv8 `crc32c*` / SSE4.2, con fallback) | nessuna dipendenza di sistema; tutto con licenze permissive, compatibili con MIT |
| **Java** | JNI su libxiz; Panama FFM (finale in JDK 22, [JEP 454](https://openjdk.org/jeps/454)); **Java puro** | **Java puro**: AES-GCM dalla JCE (con intrinseche AES/PMULL su aarch64 e x86); `java.util.zip.CRC32C` (JDK 9+); zstd da [aircompressor](https://github.com/airlift/aircompressor) (Apache-2.0, puro Java), oppure da [zstd-jni](https://github.com/luben/zstd-jni) (BSD-2, nativo) se serve velocità; Argon2id da Bouncy Castle (licenza MIT-like) | niente binari nativi da distribuire per piattaforma; funziona su JDK 11/17, dove sta gran parte delle pipeline htsjdk; Panama richiederebbe JDK 22 o successivo. **Da verificare**: il supporto di aircompressor ai dizionari zstd (XIZ §12) |
| **Python** | cffi/pybind11/nanobind su libxiz (wheel per piattaforma con cibuildwheel); **Python puro** | **Python puro**, wheel `py3-none-any`: [zstandard](https://github.com/indygreg/python-zstandard) (BSD-3, con dizionari), [cryptography](https://cryptography.io) (AESGCM, Apache-2.0/BSD), [argon2-cffi](https://github.com/hynek/argon2-cffi) (MIT). Il parsing con `struct` e `memoryview` è trascurabile rispetto a zstd e AES, che girano in C | un solo wheel; nessuna toolchain C per l'utente. Il binding cffi a libxiz si aggiunge **solo** se i benchmark lo giustificano |
| **Genomica** | decoder CRAM proprio contro uno esistente | **quello esistente**: htslib (MIT/BSD) tramite plugin; htsjdk (MIT), il cui supporto alla lettura di CRAM 3.1 **va verificato** sulla versione corrente; pysam (MIT) tramite il plugin hFILE, se la build di pysam carica i plugin (**da verificare**; altrimenti si usa `HTS_PATH` con una htslib di sistema) | con (c) nessuno deve scrivere un decoder CRAM. Con (b) ne servirebbero tre |

### 4.3 API (bozza)

**C:**
```c
xiz_t *xiz_open(const char *path, const xiz_opts *o, xiz_err *e);
xiz_t *xiz_open_io(const xiz_io *io /* size(), pread() via callback: HTTP/S3 */, const xiz_opts *o, xiz_err *e);
int    xiz_unlock(xiz_t *, const char *password, size_t len);        /* Argon2id con i limiti di §6.2 */
size_t xiz_entry_count(const xiz_t *);
int    xiz_entry_info(const xiz_t *, size_t i, xiz_entry_info *out); /* path, type, size, mtime, media, digest */
long   xiz_find(const xiz_t *, const char *path);
ssize_t xiz_pread(xiz_t *, size_t entry, void *buf, size_t len, uint64_t off);
int    xiz_verify_entry(xiz_t *, size_t entry);                      /* digest SHA-256 / HMAC */
/* genomica */
int    xiz_regions(xiz_t *, size_t entry, const char *region /* "chr1:100-200" */,
                   uint32_t groups /* XIZ_G_POS|XIZ_G_SEQ|XIZ_G_QUAL|XIZ_G_NAME|XIZ_G_TAGS */,
                   xiz_range **out, size_t *n);                       /* intervalli dell'entry da leggere */
int    xiz_reference_lookup(xiz_t *, const uint8_t md5[16], size_t *entry, char *name, size_t cap);
void   xiz_close(xiz_t *);
```

**Java:**
```java
try (var a = XizArchive.open(Path.of("cohort.xiz"), XizOptions.password(pw))) {
    for (XizEntry e : a.entries()) …;
    SeekableByteChannel ch = a.channel("NA12878.cram");          // pread su un'entry
    SamReader r = XizHtsjdk.samReader(a, "NA12878.cram");        // CRAI generato dall'XGI, reference da XIZ
    r.queryOverlapping("chr7", 55_019_017, 55_211_628);
}
```

**Python:**
```python
with xiz.open("s3://bucket/cohort.xiz", password=pw) as a:   # fsspec opzionale per gli URL
    a.list(); f = a.open("NA12878.cram")                      # file-like con seek/read
    for rng in a.regions("NA12878.cram", "chr7:55019017-55211628", groups={"pos", "seq"}): ...
```

### 4.4 Conformità e test

- **Vettori comuni** in `conformance/` (MIT): circa 40 file `.xiz` piccoli generati da Xipper, ciascuno con un `expected.json` (entry, dimensioni, SHA-256 del contenuto, esito atteso).
  - Positivi: 1.0, 1.1 con append, 1.2 con dizionario, cifrato con password nota, profilo genomico con XGI, frame allineati.
  - Negativi: CRC, footer, catalogo troncato, extent fuori dal frame, tag critico sconosciuto, AEAD alterato, Argon2 fuori dai limiti, cammino `..`, dizionario mancante, frame riordinati.
- **Runner identici** in C (ctest), Java (JUnit) e Python (pytest), che leggono gli stessi JSON. La CI li esegue su macOS arm64, Linux x86-64/arm64 e Windows.
- **Interoperabilità genomica:**
  - `samtools view xiz://…#x.cram region` contro `samtools view x.cram region`: output identico;
  - lo stesso confronto con htsjdk e pysam;
  - `bcftools view -r` su VCF/BCF.
- **Fuzzing:** libFuzzer, ASan e UBSan su `xiz_open`/`xiz_pread`/XGI, con un corpus preso dai vettori. Java e Python con Jazzer e Atheris (facoltativo).
- **Licenza:** tutto MIT. Le note di attribuzione per zstd (BSD-3), BearSSL (MIT), Argon2 (CC0/Apache-2.0) e htscodecs (BSD-3, solo per (b)) vanno nel pacchetto.

### 4.5 Impegno [stima, g-persona]

| Componente | g |
|---|---|
| Spec XIZ 1.3 (profilo genomico, XGI, lettura parziale, riferimenti) + revisione | 5–8 |
| Writer in Xipper (Swift): frame allineati per CRAM/BGZF, XGI, tag, import di `.crai`/`.tbi`/`.csi`, riferimenti per MD5 | 12–18 |
| `libxiz` core: I/O pread, mmap e callback; superblock, keys, Argon2id, HKDF; footer chain; catalogo TLV; frame, dizionari, AES-GCM, CRC32C; extent e pread; cache LRU | 15–20 |
| `libxiz` genomica: XGI, query di regione, gruppi, lookup dei riferimenti | 5–7 |
| Plugin hFILE per htslib, con test samtools/bcftools | 3–5 |
| CLI di esempio (`xizcat`, `xizls`) e build (CMake, pkg-config) | 2–3 |
| Fuzzing e hardening di libxiz | 4–6 |
| Java puro: core | 10–14 |
| Java: adattatore htsjdk (SeekableStream, CRAI dall'XGI, ReferenceSource da XIZ) | 4–6 |
| Java: pubblicazione su Maven Central (firma, javadoc) | 2–3 |
| Python puro: core, file-like, fsspec/HTTP | 8–11 |
| Python: integrazione con pysam/htslib, wheel e PyPI | 3–5 |
| Suite di conformità (vettori, generatore, 3 runner, CI multi-OS) | 8–10 |
| Benchmark (§5.2) e report in `docs/BENCHMARK.md` | 5–8 |
| **Totale con (c)** | **≈ 85–125 g** |
| In più con (b): codec nativi in Swift + decoder di record in C, Java e Python + conformità dei record | **+ 105–165 g** |

---

## 5. Raccomandazione e piano

### 5.1 Raccomandazione

> **Decisione del proprietario (23/10/2026):** per XIG ("XIZ genomico") si adotta l'**opzione (b)**, il profilo nativo (record per regione, uno stream per campo, codec htscodecs come codec di frame), invece della (c) raccomandata qui sotto. Lo stesso giorno il proprietario ha confermato di **accettare il rischio brevettuale** di (b), l'opzione più esposta a US11763918 ed EP3526706 (§3). Le regole del §3.3 restano obbligatorie. Il disegno è in [XIG_DESIGN.md](XIG_DESIGN.md).

1. **Adottare (c), "CRAM-in-XIZ", per le letture allineate, e (a) per VCF/BCF/BGZF.** Il profilo è solo opzionale: bit `genomic` più i tag 0x0009–0x000C, l'XGI e la regola della lettura parziale. Un lettore 1.2 resta in grado di estrarre tutto.
2. **`libxiz` in C come riferimento e plugin htslib come primo deliverable.** Danno subito query di regione da samtools, bcftools, IGV (tramite htslib) e pysam, senza scrivere un decoder genomico.
3. **Java e Python puri**, sullo stesso corpus di conformità.
4. **(b) resta congelato.** Lo si riapre solo se il benchmark (§5.2, B3) mostra più del 10% di guadagno su CRAM 3.1 archive **e** se il consulente brevettuale dà parere favorevole.
5. **Le varianti colonnari sono un progetto separato (fase 4).** Il modello è Zarr/GDS/pgen: chunk varianti × campioni, un array per campo. È lì che sta il guadagno di 3–300 volte, e la prior art è lontana da MPEG-G.

### 5.2 Fasi

| Fase | Contenuto | Uscita | g |
|---|---|---|---|
| **P0 Legale** | parere di un consulente brevettuale su §3.2–3.3 e sul disegno (c); verifica di EP3526712 e di US20200051665 | via libera scritto | esterno |
| **F1 Spec + writer** | XIZ 1.3 profilo genomico; Xipper scrive CRAM e VCF/BCF allineati, con XGI | archivi `.xiz` genomici; Xipper legge le regioni in Swift | 17–26 |
| **F2 libxiz + plugin htslib** | core, genomica, plugin, fuzzing, CLI | `samtools view xiz://…` | 29–41 |
| **F3 Java e Python** | lettori puri, adattatori htsjdk e pysam, pacchetti | JAR su Maven Central e wheel su PyPI | 27–39 |
| **F4 Varianti colonnari** (opzionale) | studio dedicato: chunk varianti × campioni, codec per campo (bitpacking + zstd), compatibilità con il modello VCF Zarr | studio e prototipo | da stimare |
| **Trasversale** | conformità e benchmark | suite, `BENCHMARK.md` | 13–18 |

### 5.3 Benchmark da fare

| # | Misura | Dataset | Confronto |
|---|---|---|---|
| B1 | dimensione, scrittura e lettura completa | NA12878 NovaSeq 30x, CRAM da 15,80 GB: [ERR3239334](https://ftp.sra.ebi.ac.uk/vol1/run/ERR323/ERR3239334/NA12878.final.cram) (lo stesso run di Bonfield 2022) | CRAM 3.1 normal/small/archive, BAM, CRAM-in-XIZ con e senza cifratura |
| B2 | query di regione: 1.000 regioni casuali da 1 kb, 10 kb e 1 Mb, in locale e su S3; byte letti, richieste, latenza p50/p95 | come B1, più HG002 2×250 ([GIAB novoalign BAM](https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x250bps/novoalign_bams/HG002.GRCh38.2x250.bam), 122 GB) | CRAM+CRAI con htslib, BAM+BAI, `xiz://` con gruppi G0 e G0+G1 |
| B3 | guadagno potenziale di (b): CRAM con slice da 10k contro 100k e qualità in blocchi grandi (simulazione con l'encoder Swift) | B1, chr20 | decide se riaprire (b) |
| B4 | VCF/BCF: dimensione e query di regione con (a) e (a′) | [1000G 3.202 campioni phased, chr22](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/working/20220422_3202_phased_SNV_INDEL_SV/) (425 MB); [GIAB v4.2.1 HG002](https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG002_NA24385_son/NISTv4.2.1/GRCh38/HG002_GRCh38_1_22_v4.2.1_benchmark.vcf.gz) (156 MB) | VCF.gz + tbi, BCF + csi, e come riferimento per la fase 4 VCF Zarr (bio2zarr) |
| B5 | dedup del riferimento: archivio di coorte con 10 CRAM e FASTA | [GRCh38 full analysis set](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome/GRCh38_full_analysis_set_plus_decoy_hla.fa) (3,26 GB) | 10 CRAM + FASTA separati, oppure CRAM con riferimento incorporato |
| B6 | lettori: throughput di `pread` sequenziale e casuale, apertura a freddo, C contro Java contro Python | B1 | — |

### 5.4 Rischi

| Rischio | Impatto | Mitigazione |
|---|---|---|
| Brevetti, in particolare le domande pendenti di Philips (US20200051665) e le continuation | alto per (b), basso per (c) | P0; le regole del §3.3; nessuna funzione "MPEG-like" senza parere |
| htslib non tollera blocchi CRAM assenti con `required_fields` | medio: i gruppi di colonne diventano solo un risparmio di decodifica, non di I/O | blocchi vuoti sintetici; altrimenti per htslib si leggono le slice intere e i gruppi si usano solo nei lettori nostri |
| Catalogo grande su WGS con molti frame (3–8 MB) | basso o medio per l'accesso remoto | slice da 25k (profilo small); XGI paginato fuori dal catalogo; in futuro un catalogo paginato (XIZ 2) |
| Tre implementazioni da mantenere allineate | medio | spec unica, corpus unico, CI comune; Java e Python sono solo lettori |
| Privacy delle dimensioni dei frame negli archivi cifrati | basso | padding opzionale; documentarlo nella spec |
| Pochi utenti di archivi "XIZ genomici" fuori da Xipper | medio | export byte-esatto in CRAM/VCF; il plugin htslib rende il formato leggibile dagli strumenti standard |
| (a′) e BAM→CRAM non sono byte-esatti | medio: viola "estrai = originale" | presentarli come **importazione o conversione**, mai come archiviazione; byte-esatto di default |

### 5.5 Domande aperte per il proprietario

1. **Parere brevettuale (P0):** lo si chiede prima della F1, o si procede con (c) considerandolo prior art sufficiente e si chiede il parere solo prima di (b)?
2. **Ambito:** bastano CRAM e VCF/BCF, o servono anche FASTQ (non allineati) nel profilo? Per i FASTQ l'unica via pulita è BGZF o zstd in frame: niente clustering (§3.3).
3. **BAM in ingresso:** archiviarlo byte-esatto (store, ratio BAM) o proporre la conversione in CRAM (con riferimento) come azione separata?
4. **Lettori in Java e Python:** servono subito (a chi? pipeline interne di GenomeUp?) o basta `libxiz` con il plugin htslib per la prima release?
5. **Rete:** il backend htsget e l'accesso S3 entrano in Xipper (opt-in, STUDIO §4.6) o restano solo nelle librerie?
6. **Licenza e governance** della spec XIZ: resta in questo repository o va in un repository `xiz-spec` separato, MIT/CC-BY, con i vettori di conformità?
7. **Fase 4 colonnare:** c'è una domanda concreta (coorti di VCF con molti campioni) che la giustifichi?

---

## Fonti

- **Formati e indici:** [CRAMv3](https://samtools.github.io/hts-specs/CRAMv3.pdf), [tabix](https://samtools.github.io/hts-specs/tabix.pdf), [CSIv1](https://samtools.github.io/hts-specs/CSIv1.pdf), [htsget](https://samtools.github.io/hts-specs/htsget.html), [refget](https://samtools.github.io/hts-specs/refget.html), [benchmark CRAM di htslib](https://www.htslib.org/benchmarks/CRAM.html), [samtools(1)](https://www.htslib.org/doc/samtools.html).
- **Articoli:**
  - Bonfield, *CRAM 3.1*, Bioinformatics 38(6) 2022, [doi:10.1093/bioinformatics/btac010](https://doi.org/10.1093/bioinformatics/btac010);
  - Li, *Tabix*, Bioinformatics 27(5) 2011, [link](https://academic.oup.com/bioinformatics/article/27/5/718/262743);
  - Czech et al., *Analysis-ready VCF at Biobank scale using Zarr*, GigaScience 2025, [PMC12127038](https://pmc.ncbi.nlm.nih.gov/articles/PMC12127038/);
  - Zheng et al., *SeqArray*, Bioinformatics 33(15) 2017, [link](https://academic.oup.com/bioinformatics/article/33/15/2251/3072873);
  - LeFaive et al., *Savvy*, Bioinformatics 37(22) 2021, [PMC9502232](https://pmc.ncbi.nlm.nih.gov/articles/PMC9502232/);
  - Hafidi et al., PVLDB 18(11) 2025, [pdf](https://www.vldb.org/pvldb/vol18/p4045-hafidi.pdf);
  - Poterba et al., *SVCR/VDS*, [bioRxiv](https://doi.org/10.1101/2024.01.09.574205);
  - Müntefering et al., *Genie*, Commun Biol 7:553 2024, [doi](https://doi.org/10.1038/s42003-024-06249-8);
  - Alberti et al., *An introduction to MPEG-G*, [bioRxiv 2018](https://doi.org/10.1101/426353);
  - Genozip 14, [bioRxiv 2022](https://doi.org/10.1101/2022.09.12.507582);
  - Campagne et al., *Goby*, PLoS ONE 2013, [doi](https://doi.org/10.1371/journal.pone.0079871);
  - Bonfield & Mahoney, *samcomp/fqzcomp*, PLoS ONE 2013, [PMC3606433](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3606433/).
- **Strumenti e specifiche colonnari:** [vcf-zarr-spec](https://github.com/sgkit-dev/vcf-zarr-spec), [bio2zarr](https://github.com/sgkit-dev/bio2zarr), [pgen spec](https://github.com/chrchang/plink-ng/blob/master/pgen_spec/pgen_spec.tex), [TileDB-VCF](https://github.com/TileDB-Inc/TileDB-VCF), [Hail MatrixTable](https://hail.is/docs/0.2/overview/matrix_table.html), [ADAM storage benchmark](https://adam.readthedocs.io/en/latest/benchmarks/storage/), [Glow](https://github.com/projectglow/glow), [vcf2parquet](https://github.com/natir/vcf2parquet).
- **Brevetti** (Google Patents, consultati il 23/10/2026): [EP3526711B1](https://patents.google.com/patent/EP3526711B1/en), [US11404143B2](https://patents.google.com/patent/US11404143B2/en), [US11386979B2](https://patents.google.com/patent/US11386979B2/en), [US11763918B2](https://patents.google.com/patent/US11763918B2/en), [EP3526706B1](https://patents.google.com/patent/EP3526706B1/en), [EP3526709B1](https://patents.google.com/patent/EP3526709B1/en), [EP3526712B1](https://patents.google.com/patent/EP3526712B1/en), [EP3311318B1](https://patents.google.com/patent/EP3311318B1/en), [EP3652862B1](https://patents.google.com/patent/EP3652862B1/en), [US10938415B2](https://patents.google.com/patent/US10938415B2/en), [US20200051665A1](https://patents.google.com/patent/US20200051665A1/en), [US10902937B2](https://patents.google.com/patent/US10902937B2/en) (IBM, classificazione per mismatch, 2014). Blog di J. Bonfield: [MPEG-G: the ugly](http://datageekdom.blogspot.com/2018/09/mpeg-g-ugly.html), [archivio 09/2018](http://datageekdom.blogspot.com/2018/09/).
- **Librerie:** [JEP 454 (FFM)](https://openjdk.org/jeps/454), [aircompressor](https://github.com/airlift/aircompressor), [zstd-jni](https://github.com/luben/zstd-jni), [python-zstandard](https://github.com/indygreg/python-zstandard), [cryptography](https://cryptography.io), [argon2-cffi](https://github.com/hynek/argon2-cffi), [BearSSL](https://bearssl.org), [htslib](https://github.com/samtools/htslib), [htsjdk](https://github.com/samtools/htsjdk), [pysam](https://github.com/pysam-developers/pysam).
- **Dati:** [GIAB HG002](https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/), [1000G high coverage](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/), [GRCh38 analysis set](https://ftp.1000genomes.ebi.ac.uk/vol1/ftp/technical/reference/GRCh38_reference_genome/).

*I numeri marcati [stima] sono deduzioni da verificare con i benchmark del §5.3. Le cifre dei brevetti (scadenze, titolari) sono stime di Google Patents, non conclusioni legali.*

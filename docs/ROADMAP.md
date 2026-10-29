# Roadmap di Xipper

Aggiornata al 21/10/2026. Le decisioni di fondo sono in [STUDIO.md](../STUDIO.md), lo stato dell'app in [FASE2.md](../FASE2.md).

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

---

## XIG: profilo genomico nativo di XIZ

- ✅ **decisione** (23/10/2026): opzione (b) dello studio genomico, con il rischio brevettuale accettato dal proprietario; disegno in [XIG_DESIGN.md](XIG_DESIGN.md);
- X1 prototipo Swift e benchmark B3 (soglia: ≥5% meno di CRAM 3.1 normal); X2 spec XIZ 1.3; X3 Xipper completo; X4 libxiz in C con plugin htslib; X5 lettori Java e Python;
- ✅ **decisioni** (23/10/2026, [XIG_DESIGN.md §11](XIG_DESIGN.md)): estensione `.xig` per gli archivi genomici e `.xiz` per gli altri; Java puro (codec di htsjdk), Python puro con binding nativo solo per i codec; FASTQ in backlog; slice 10k e span 10 provvisori; mate collegati se cadono nella stessa slice, come CRAM 3.0;
- primo benchmark sul BAM reale (chr20, 6,6 M letture, senza riferimento): XIG 106,6 MB contro CRAM 3.1 normal 106,7 MB e archive 91,7 MB, con lo scrittore di prova in Java; mancano le misure con riferimento e i mate collegati;
- lettore XIG per IGV, in una sessione separata (branch `xig` di un fork locale, non pubblicato).

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

# Roadmap di Xipper

Aggiornata al 21/10/2026. Le decisioni di fondo sono in [STUDIO.md](../STUDIO.md), lo stato dell'app in [FASE2.md](../FASE2.md).

**Distribuzione:** solo DMG su GitHub, firmato self-signed. Gli aggiornamenti si controllano a mano dall'app. Niente Developer ID né Mac App Store per ora.

---

## 1.0: uscita dalla beta

| # | Attività | Stato |
|---|---|---|
| 1 | Test manuali da fare a mano: Touch ID sulla password salvata, trascinamento di una voce dal browser al Finder, azioni di Comandi Rapidi | da fare (serve una persona) |
| 2 | Feedback dei tester su beta3 e beta4 e correzione delle issue | in corso |
| 3 | Nuova grafica: icone dei documenti per formato, glifo piccolo dell'icona, simbolo della barra dei menu, sfondo del DMG, illustrazione di benvenuto (prompt in [design/icon-sprite-prompt.md](design/icon-sprite-prompt.md)) | in attesa degli sprite |
| 4 | Passata finale sui testi italiani e inglesi, note di versione 1.0 | da fare |
| 5 | Controllo del marchio "Xipper" (EUIPO/UIBM/USPTO, classi 9 e 42) | da fare prima del lancio pubblico |
| 6 | Tag `v1.0.0` non pre-release: l'aggiornamento lo propone a tutti, beta comprese | ultimo passo |

Restano **fuori dalla 1.0** per scelta: RAR, ZIP Deflate64, scrittura di lz4 e brotli. XIZ è diventato stabile il 22/10/2026 (formato 1.0, vedi sotto).

---

## 2.0

### 1. ⭐ Montaggio degli archivi come volume (prima priorità)

L'archivio si apre come un volume in sola lettura: lo si sfoglia nel Finder e le app aprono i file senza estrarre. Nessun concorrente lo offre in modo nativo.

- **Spike fatto il 21/10/2026 → [FSKIT.md](FSKIT.md):**
  - il modulo si registra e si attiva, e `FSPathURLResource` (macOS 26) monta un file;
  - ma `com.apple.developer.fskit.fsmodule` è un **entitlement riservato**: con la firma self-signed AMFI rifiuta l'estensione ("No matching profile found").
- **Decisione del 21/10/2026: niente account Apple.** Si usa l'opzione C, un **server WebDAV locale** in sola lettura montato con il client di macOS.
  - Lo spike funziona: montaggio come utente, contenuto identico, si smonta da solo se il server cade.
  - Limite: il client scarica l'intero file alla prima apertura.
  - Dettagli in [FSKIT.md](FSKIT.md).
- **Fatto il 21/10/2026: montaggio in lettura e scrittura su WebDAV.** CLI `xipper mount`, «Monta»/«Espelli» nel browser e nel Finder, salvataggio delle modifiche all'espulsione. Dettagli in [FSKIT.md](FSKIT.md), sezione "Implementazione".
- **Da completare (con FSKit se un giorno ci sarà un account):**
  - volume in sola lettura per ZIP (anche AES con la password dal portachiavi), tar non compresso e tar.zst/XIZ con accesso casuale ai frame;
  - azione «Monta» nel browser, nel menu del Finder e nella CLI (`xipper mount`), «Espelli» dal Finder;
  - GET in streaming e cache dei blocchi decompressi con limite di memoria; credenziali casuali per ogni montaggio (NetFS);
  - date e dimensioni come nell'archivio. Permessi e xattr solo con FSKit o NFS.
- **Poi:**
  - 7z non solido (i blocchi solidi richiedono decompressione sequenziale: cache per cartella);
  - tar.gz/xz senza indice: letture sequenziali con avviso, oppure indice costruito al primo montaggio;
  - BGZF con indice `.gzi`.
- **Sicurezza:**
  - stesse regole dell'estrazione sicura: nessun symlink verso l'esterno, nomi validati, limiti di memoria contro le zip-bomb;
  - fuzzing del percorso di montaggio.
- **Test:**
  - montaggio e smontaggio automatici;
  - confronto byte per byte con l'estrazione;
  - accesso concorrente da più app;
  - Quick Look sul volume; server terminato con il volume montato.

### 2. ⭐ Ottimizzazioni in assembler ARM64/NEON e GPU

Sui punti caldi misurati:

- decodifica LZMA/LZMA2 (c'è già il ciclo ARM64 di 7-Zip) e deflate;
- match finder;
- Huffman/FSE;
- CRC-32/CRC-32C/XXH;
- AES.

Ogni ottimizzazione deve avere un percorso portabile di riserva, test di equivalenza e un benchmark in [BENCHMARK.md](BENCHMARK.md). GPU (Metal) solo dove il guadagno è misurabile, per esempio sulla compressione a blocchi indipendenti di XIZ.

### 3. XIZ stabile (v1 del formato)

**Fatto il 22/10/2026: XIZ 1.0, formato congelato, fuori dalla beta.** Specifica pubblica: [XIZ_SPEC.md](XIZ_SPEC.md).

- ✅ cifratura autenticata di dati e nomi (Argon2id, AES-256-GCM, catalogo STREAM);
- ✅ chunking basato sul contenuto (FastCDC, deduplicazione dentro i file);
- ✅ catalogo estensibile (campi TLV con bit "critico") e flag delle funzioni obbligatorie e facoltative;
- ✅ XIZ 1.1 (22/10/2026): **modifica in place** con segmenti aggiunti in coda (rinomina, elimina, aggiungi senza riscrivere nulla; `compact` per recuperare spazio);
- ✅ dati di recupero: file **PAR2** standard accanto all'archivio (vale per XIZ e per ogni altro formato);
- da fare: dizionari addestrati per i file piccoli (funzione obbligatoria `dictionaries`);
- ordinamento per somiglianza: è una scelta del compressore, il formato non cambia.

### 4. Robustezza e riparazione — ✅ 22/10/2026

- ✅ dati di recupero **PAR2** scritti da zero dalla specifica (Reed-Solomon su GF(2^16)), compatibili con par2cmdline e MultiPar: `xipper par2 create|verify|repair`, «Crea dati di recupero» nell'inspector, opzione per crearli dopo ogni compressione;
- ✅ «Ripara» nella vista delle voci danneggiate quando c'è un `.par2`;
- da fare: ricerca dei blocchi spostati (come par2cmdline), accelerazione NEON di GF(2^16) (punto 2).

### 5. Modifica degli archivi — ✅ 22/10/2026

- ✅ `Xipper.edit` / `xipper edit`: elimina, rinomina, aggiungi (le cartelle si fondono), crea cartelle;
  - ZIP: le voci non toccate vengono copiate così come sono (anche AES e data descriptor), solo il nuovo viene compresso;
  - XIZ: segmento aggiunto in coda, nulla viene riscritto;
  - altri formati: ricostruiti nel loro formato e con la loro password;
- ✅ nel browser: «Rinomina…», «Elimina», «Aggiungi file…» e trascinamento di file dentro la tabella;
- ✅ il salvataggio dei volumi montati usa lo stesso percorso (ZIP e XIZ non ricomprimono più tutto);
- da fare: 7z non solido senza ricompressione.

### 6. Formati in sola lettura

- **RAR/RAR5:** implementazione clean-room, §4.2 di STUDIO;
- **ISO 9660/UDF** e **DMG** non cifrati.

### 7. Automazione

- cartelle sorvegliate (comprimi o estrai all'arrivo);
- Tasks MCP per i lavori lunghi;
- nuove azioni di Comandi Rapidi (monta, manifest).

### 8. Genomica

- tabix per formati aggiuntivi;
- **CRAM 3.1** in lettura e scrittura (GA4GH, nessun nodo brevettuale noto): è l'opzione preferita per la genomica compressa;
- MPEG-G: al massimo il riconoscimento dei file `.mgb`/`.mgg`. Decodifica e codifica solo dopo la verifica legale (G0 in STUDIO §4.5, analisi del 21/10/2026).

---

## Principi che valgono per ogni versione

- Nessuna dipendenza esterna a runtime: i codec restano compilati dentro l'app.
- L'estrazione sicura è condivisa da tutti i formati e da FSKit; ogni nuovo lettore entra nel fuzzing.
- Ogni funzione arriva con test automatici; quello che si può provare solo a mano viene annotato in FASE2.md.

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

Restano **fuori dalla 1.0** per scelta: XIZ (BETA dietro l'interruttore), RAR, ZIP Deflate64, scrittura di lz4 e brotli.

---

## 2.0

### 1. ⭐ Montaggio degli archivi con FSKit (prima priorità)

L'archivio si apre come un volume in sola lettura: lo si sfoglia nel Finder e le app aprono i file senza estrarre. Nessun concorrente lo offre in modo nativo.

- **Spike (prima di tutto):**
  - verificare che un modulo FSKit (`FSUnaryFileSystem`, macOS 15.4+) si possa caricare con la firma self-signed: l'estensione richiede l'entitlement `com.apple.developer.fskit.fsmodule`, che potrebbe richiedere un profilo di provisioning;
  - se serve, valutare un account sviluppatore gratuito o rivedere la decisione sulla distribuzione;
  - misurare la latenza delle letture casuali.
- **MVP:**
  - estensione `XipperFS` in sola lettura per ZIP (anche AES con la password dal portachiavi), tar non compresso e tar.zst/XIZ con accesso casuale ai frame;
  - azione «Monta» nel browser, nel menu del Finder e nella CLI (`xipper mount`), «Espelli» dal Finder;
  - cache dei blocchi decompressi con limite di memoria, metadati (permessi, date, xattr) esposti come nel Finder.
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
  - Spotlight e Quick Look sul volume.

### 2. ⭐ Ottimizzazioni in assembler ARM64/NEON e GPU

Sui punti caldi misurati:

- decodifica LZMA/LZMA2 (c'è già il ciclo ARM64 di 7-Zip) e deflate;
- match finder;
- Huffman/FSE;
- CRC-32/CRC-32C/XXH;
- AES.

Ogni ottimizzazione deve avere un percorso portabile di riserva, test di equivalenza e un benchmark in [BENCHMARK.md](BENCHMARK.md). GPU (Metal) solo dove il guadagno è misurabile, per esempio sulla compressione a blocchi indipendenti di XIZ.

### 3. XIZ stabile (v1 del formato)

Il formato si congela (niente più cambi incompatibili) ed esce dalla beta. Fasi 2 e 3 dello [studio del formato](reports/):

- cifratura autenticata di dati e nomi;
- chunking basato sul contenuto (deduplicazione dentro i file);
- dizionari addestrati per i file piccoli;
- ordinamento per somiglianza;
- dati di recupero;
- aggiunta di file a un archivio esistente.

Serve una specifica pubblica del formato.

### 4. Robustezza e riparazione

- dati di recupero **PAR2** (formato aperto) per ZIP, 7z e tar;
- riparazione guidata dalla vista delle voci danneggiate.

### 5. Modifica degli archivi

- aggiungere, rinominare ed eliminare voci di ZIP e 7z senza ricreare l'archivio dove il formato lo permette;
- trascinare file dentro il browser.

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

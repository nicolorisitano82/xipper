# Xipper 3.1

*Italiano · [English](README-USER.en.md)*

Xipper è un archiviatore per Mac con Apple Silicon (M1 o successivi) e **macOS 26 o successivo**. Crea, apre, verifica, ripara ed estrae archivi in modo veloce e sicuro: ZIP, 7z, tar (gz, bz2, xz, zst, lz4, br), lz4, brotli, cpio, Apple Archive e XIZ, il formato di Xipper; apre anche i RAR, compresi i RAR5 cifrati. Per la genomica converte BAM ↔ CRAM 3.1 e crea gli indici che usano samtools, bcftools e tabix.

## Installazione
1. Apri il file `.dmg` di Xipper e trascina **Xipper** nella cartella **Applicazioni**.
2. **Primo avvio.** Xipper è firmato con un certificato proprio, non con un Developer ID Apple, quindi macOS lo blocca la prima volta.
   - Apri Xipper. Al messaggio "non è possibile verificare lo sviluppatore" scegli **Fine**.
   - Vai in **Impostazioni di Sistema › Privacy e sicurezza**, scorri fino a "Xipper è stata bloccata" e premi **Apri comunque**. Conferma con la password o Touch ID.
   - In alternativa, da Terminale:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Xipper.app
     ```

3. Verifica, se vuoi: l'impronta SHA-256 del DMG è nel file `.sha256` che lo accompagna.

## Cosa fa
- **Comprimi:** trascina file e cartelle nella finestra, scegli formato, livello ed eventuale password (ZIP, 7z e XIZ con AES-256; Apple Archive con AEA). Gli ZIP si possono creare anche con bzip2, LZMA, xz e Deflate64 (menu Formato › Altri metodi ZIP), leggibili da 7-Zip e WinZip ma non da Utility Archivio.
- **Apri e sfoglia:** doppio clic su un archivio; anteprima con la barra spaziatrice, trascinamento dei file sulla Scrivania.
- **Estrai:** accanto all'archivio, oppure le voci scelte dove vuoi. Xipper non scrive mai fuori dalla destinazione, blocca le zip-bomb e mantiene la quarantena dei file scaricati.
- **Modifica senza estrarre:** nel browser, tasto destro › **Rinomina…**, **Elimina**, **Aggiungi file…**, oppure trascina file nella tabella. Con ZIP, 7z e XIZ quello che non cambia non viene ricompresso (in un 7z solido si ricomprimono solo i blocchi toccati).
- **Monta come volume:** pulsante **Monta** (o Finder › Xipper › Monta come volume). L'archivio compare in `/Volumes`, lo apri e lo modifichi nel Finder; quando lo espelli Xipper chiede se salvare le modifiche.
- **Verifica e ripara:** **Verifica** controlla l'integrità senza scrivere nulla. Con **Crea dati di recupero** (inspector) Xipper scrive file PAR2 accanto all'archivio; se un giorno l'archivio si danneggia, **Ripara** lo ricostruisce, anche quando dei dati sono stati spostati da un'inserzione o una cancellazione. Negli XIZ i dati di recupero possono stare dentro l'archivio (Impostazioni › Generali › Dati di recupero), con una verifica mensile facoltativa in background.
- **Foto più piccole:** con Impostazioni › Formati › XIZ › «Foto JPEG più piccole» i JPEG occupano circa il 20% in meno e all'estrazione tornano identici byte per byte (archivi leggibili da Xipper 2.7 in poi).
- **Tabelle più piccole:** con Impostazioni › Formati › XIZ › «Tabelle CSV più piccole» i file CSV, TSV e BED vengono compressi colonna per colonna con OpenZL: le tabelle di numeri occupano dal 10 al 30% in meno che al livello Massimo, si aprono più in fretta e all'estrazione tornano identiche byte per byte (archivi leggibili da Xipper 3.1 in poi; da riga di comando `xipper create --tables`).
- **Archivi forensi:** gli archivi creati da Xipper Forensic (prodotto separato) si aprono, si verificano e si estraggono come gli altri XIZ; l'inspector mostra in sola lettura il caso, il reperto, l'impronta della sorgente e i passaggi di mano.
- **PNG, PDF e documenti più piccoli:** con Impostazioni › Formati › XIZ › «PNG, PDF e documenti più piccoli» Xipper ricomprime i dati interni di PNG, PDF e documenti Office ed EPUB: sui file veri i PNG occupano circa il 30% in meno, i PDF il 17%, i documenti il 13%, e all'estrazione tornano identici byte per byte (archivi leggibili da Xipper 3.0 in poi).
- **Codec di Apple:** su macOS 27, Impostazioni › Formati › XIZ › «Codec di Apple (LZRAVEN e LZMESH)» usa i compressori di Apple: archivi più piccoli di LZMA2 al livello Massimo, più veloci da aprire agli altri livelli. Si leggono solo su macOS 27.
- **Versioni:** ogni modifica di un XIZ ne conserva la versione precedente. Nell'inspector, la sezione **Versioni** apre in sola lettura com'era l'archivio prima; **Aggiorna da una cartella…** aggiunge i file nuovi o cambiati e toglie quelli spariti (anche da riga di comando: `xipper versions`, `xipper update`).
- **Cambia formato con poco spazio:** da ZIP o 7z a XIZ, **Cambia formato…** propone «Converti con poco spazio libero» quando il disco non basta per tenere i due archivi: Xipper converte un blocco alla volta e libera man mano lo spazio dell'originale, che alla fine viene eliminato. Se si interrompe, anche per un calo di corrente, riaprendo l'originale Xipper riprende da dove era arrivato.
- **XIZ per dati sensibili:** con il formato XIZ, il pulsante **Accesso** imposta le cartelle riservate, chi apre cosa (password o chiave pubblica), i gruppi di custodi (per esempio 2 su 3 devono sbloccare insieme), i file cancellabili e la tua firma. Le tue chiavi stanno nel Portachiavi (**Impostazioni › Chiavi**, Touch ID); le nuove identità sono post-quantum (X-Wing: ML-KEM-768 + X25519), così un archivio registrato oggi resta protetto anche da futuri computer quantistici. In un archivio, l'inspector mostra la cronologia firmata; con il tasto destro su un file ci sono **Crea prova di appartenenza…** e **Cancella definitivamente…**; **Archivio › Verifica prova di appartenenza…** controlla una prova. Le stesse cose da riga di comando: ognuno accede solo alle sue cartelle (password o chiave pubblica), una parte si apre solo con 2 custodi su 3, ogni modifica è firmata, così `xipper history` mostra chi ha cambiato cosa e quando; si può provare che un file appartiene all'archivio senza consegnare il resto (`prove`, `verify-proof`) e cancellare un file in modo definitivo (`erase`, negli archivi creati come cancellabili; le copie fatte prima lo conservano). `xipper help` elenca le opzioni.
- **Genomica:**
  - BGZF compatibile con `bgzip`;
  - **CRAM 3.1**: apri un `.cram` o un `.bam` e usa **Converti in BAM…** / **Converti in CRAM…** con il riferimento FASTA (il CRAM è di solito il 30–50% più piccolo del BAM, e samtools lo legge);
  - indici `.bai`/`.csi`, `.crai`, `.csi` dei BCF, `.fai` e tabix (anche per SAM);
  - verifica di VCF/BCF/BAM/CRAM e manifest dei checksum.

Xipper parla italiano, inglese, tedesco, francese, spagnolo, giapponese e cinese semplificato, e annuncia a VoiceOver l'avanzamento dei lavori. I RAR e i 7z vengono decodificati in un processo separato e isolato: un archivio malformato non può far chiudere Xipper.

## Integrazione con il Finder
Al primo avvio Xipper mostra un'introduzione con tre passaggi facoltativi: estensione del Finder, app predefinita per gli archivi e comando `xipper` nel Terminale. Si riapre da **Aiuto › Introduzione a Xipper**.

- **Menu Xipper e pulsante nella toolbar:** attiva **Xipper nel Finder** in **Impostazioni di Sistema › Generali › Elementi login ed estensioni › Estensioni del Finder**.
- **Azioni rapide / Servizi:** **Comprimi con Xipper**, **Estrai con Xipper**, **Verifica con Xipper**.
- **Quick Look** degli archivi e **Comandi Rapidi** (Comprimi, Estrai, Verifica, Elenca contenuto).

Il menu di Xipper nel Finder propone per prima l'azione adatta: **Decomprimi** sugli archivi, **Comprimi** sul resto; le altre sono in **Altro con Xipper**.

Le azioni dal Finder creano sempre file nuovi accanto agli originali e non sovrascrivono mai nulla.

## Limiti noti
- **RAR** si apre in sola lettura (anche a volumi); i RAR5 cifrati si aprono con la loro password, non ancora i RAR 4 cifrati né i RAR5 cifrati a volumi; ISO, DMG e MPEG-G sono in programma, senza una data.
- I CRAM non si sfogliano come archivi: si convertono in BAM, con il riferimento FASTA usato per scriverli.
- Gli Apple Archive cifrati richiedono una password di almeno 20 caratteri (limite di macOS).
- Il volume montato è un volume WebDAV locale: alla prima apertura di un file molto grande il Mac lo legge tutto.

## Riconoscimenti
Xipper include codice open source (zstd, libdeflate, liblzma, htscodecs, libarchive, Argon2, LZMA SDK, Brotli, brunsli, preflate, OpenZL): le licenze sono in **Xipper › Riconoscimenti**.

## Aggiornamenti
Una volta al giorno Xipper chiede a GitHub se c'è una versione nuova (anche da **Xipper › Cerca aggiornamenti…**). Se c'è, la scarica solo se glielo dici, la controlla con l'impronta SHA-256 e apre l'immagine disco: trascini Xipper in **Applicazioni** come la prima volta.

## Privacy
Xipper non raccoglie dati. L'unico collegamento a Internet è il controllo degli aggiornamenti su GitHub, che si può disattivare in **Impostazioni › Generali**.

## Problemi
Apri una issue su <https://github.com/nicolorisitano82/xipper/issues> con la versione di macOS, cosa hai fatto e cosa è successo.

# Xipper 2.0

*Italiano · [English](README-USER.en.md)*

Xipper è un archiviatore per Mac con Apple Silicon (M1 o successivi) e **macOS 26 o successivo**. Crea, apre, verifica, ripara ed estrae archivi in modo veloce e sicuro: ZIP, 7z, tar (gz, bz2, xz, zst), cpio, Apple Archive e XIZ, il formato di Xipper. Per la genomica converte BAM ↔ CRAM 3.1 e crea gli indici che usano samtools, bcftools e tabix.

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
- **Comprimi:** trascina file e cartelle nella finestra, scegli formato, livello ed eventuale password (ZIP, 7z e XIZ con AES-256; Apple Archive con AEA). Gli ZIP si possono creare anche con bzip2, LZMA e xz (menu Formato › Altri metodi ZIP), leggibili da 7-Zip e WinZip ma non da Utility Archivio.
- **Apri e sfoglia:** doppio clic su un archivio; anteprima con la barra spaziatrice, trascinamento dei file sulla Scrivania.
- **Estrai:** accanto all'archivio, oppure le voci scelte dove vuoi. Xipper non scrive mai fuori dalla destinazione, blocca le zip-bomb e mantiene la quarantena dei file scaricati.
- **Modifica senza estrarre:** nel browser, tasto destro › **Rinomina…**, **Elimina**, **Aggiungi file…**, oppure trascina file nella tabella. Con ZIP e XIZ quello che non cambia non viene ricompresso.
- **Monta come volume:** pulsante **Monta** (o Finder › Xipper › Monta come volume). L'archivio compare in `/Volumes`, lo apri e lo modifichi nel Finder; quando lo espelli Xipper chiede se salvare le modifiche.
- **Verifica e ripara:** **Verifica** controlla l'integrità senza scrivere nulla. Con **Crea dati di recupero** (inspector) Xipper scrive file PAR2 accanto all'archivio; se un giorno l'archivio si danneggia, **Ripara** lo ricostruisce.
- **Genomica:**
  - BGZF compatibile con `bgzip`;
  - **CRAM 3.1**: apri un `.cram` o un `.bam` e usa **Converti in BAM…** / **Converti in CRAM…** con il riferimento FASTA (il CRAM è di solito il 30–50% più piccolo del BAM, e samtools lo legge);
  - indici `.bai`/`.csi`, `.crai`, `.csi` dei BCF, `.fai` e tabix (anche per SAM);
  - verifica di VCF/BCF/BAM/CRAM e manifest dei checksum.

## Integrazione con il Finder
Al primo avvio Xipper mostra un'introduzione con tre passaggi facoltativi: estensione del Finder, app predefinita per gli archivi e comando `xipper` nel Terminale. Si riapre da **Aiuto › Introduzione a Xipper**.

- **Menu Xipper e pulsante nella toolbar:** attiva **Xipper nel Finder** in **Impostazioni di Sistema › Generali › Elementi login ed estensioni › Estensioni del Finder**.
- **Azioni rapide / Servizi:** **Comprimi con Xipper**, **Estrai con Xipper**, **Verifica con Xipper**.
- **Quick Look** degli archivi e **Comandi Rapidi** (Comprimi, Estrai, Verifica, Elenca contenuto).

Il menu di Xipper nel Finder propone per prima l'azione adatta: **Decomprimi** sugli archivi, **Comprimi** sul resto; le altre sono in **Altro con Xipper**.

Le azioni dal Finder creano sempre file nuovi accanto agli originali e non sovrascrivono mai nulla.

## Limiti noti
- **RAR** si apre in sola lettura (anche a volumi), ma non ancora quelli cifrati; ISO e MPEG-G arriveranno con la 3.0; ZIP Deflate64 non è supportato; **lz4 e brotli** si aprono ma non si creano.
- I CRAM non si sfogliano come archivi: si convertono in BAM, con il riferimento FASTA usato per scriverli.
- Gli Apple Archive cifrati richiedono una password di almeno 20 caratteri (limite di macOS).
- Il volume montato è un volume WebDAV locale: alla prima apertura di un file molto grande il Mac lo legge tutto.
- La riparazione PAR2 confronta i blocchi nella loro posizione: i dati spostati all'interno del file non vengono cercati.

## Riconoscimenti
Xipper include codice open source (zstd, libdeflate, liblzma, htscodecs, libarchive, Argon2, LZMA SDK): le licenze sono in **Xipper › Riconoscimenti**.

## Aggiornamenti
Una volta al giorno Xipper chiede a GitHub se c'è una versione nuova (anche da **Xipper › Cerca aggiornamenti…**). Se c'è, la scarica solo se glielo dici, la controlla con l'impronta SHA-256 e apre l'immagine disco: trascini Xipper in **Applicazioni** come la prima volta.

## Privacy
Xipper non raccoglie dati. L'unico collegamento a Internet è il controllo degli aggiornamenti su GitHub, che si può disattivare in **Impostazioni › Generali**.

## Problemi
Apri una issue su <https://github.com/nicolorisitano82/xipper/issues> con la versione di macOS, cosa hai fatto e cosa è successo.

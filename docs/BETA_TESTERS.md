# Xipper 0.9.0 beta2: note per i tester

Grazie per provare Xipper! È un archiviatore per Mac con Apple Silicon (M1 o successivi) e **macOS 26 o successivo**. Crea, apre, verifica ed estrae archivi in modo veloce e sicuro.

## Installazione
1. Apri `Xipper-0.9.0-beta2.dmg` e trascina **Xipper** nella cartella **Applicazioni**.
2. **Primo avvio.** La beta è firmata con un certificato di sviluppo, non con un Developer ID Apple, quindi macOS la blocca la prima volta.
   - Apri Xipper. Al messaggio "non è possibile verificare lo sviluppatore" scegli **Fine**.
   - Vai in **Impostazioni di Sistema › Privacy e sicurezza**, scorri fino a "Xipper è stata bloccata" e premi **Apri comunque**. Conferma con la password o Touch ID.
   - In alternativa, da Terminale:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Xipper.app
     ```

3. Verifica, se vuoi: l'impronta SHA-256 del DMG è nel file `.sha256` che lo accompagna.

## Integrazione con il Finder
Al primo avvio Xipper mostra un'introduzione con tre passaggi facoltativi: estensione del Finder, app predefinita per gli archivi e comando `xipper` nel Terminale. Si riapre da **Aiuto › Introduzione a Xipper**.

- **Menu Xipper e pulsante nella toolbar** (Finder Sync): vai in **Impostazioni di Sistema › Generali › Elementi login ed estensioni › Estensioni del Finder** e attiva **Xipper nel Finder**. Nel menu contestuale compare **Xipper ▸** con le voci:
  - Comprimi;
  - Estrai qui;
  - Verifica;
  - Apri in Xipper.

  Per il pulsante in toolbar: tasto destro sulla toolbar del Finder › **Personalizza barra strumenti…** › trascina "Xipper".
- **Azioni rapide / Servizi:** **Comprimi con Xipper**, **Estrai con Xipper**, **Verifica con Xipper**. Si trovano nel menu contestuale, sotto **Azioni rapide** o **Servizi**. Se non compaiono, attivale in **Impostazioni di Sistema › Tastiera › Scorciatoie da tastiera › Servizi › File e cartelle**.

- **Quick Look:** seleziona un archivio nel Finder e premi la barra spaziatrice per vederne il contenuto. Le icone degli archivi mostrano il formato (e, per gli ZIP, il numero di file).
- **Comandi Rapidi:** nell'app Comandi Rapidi cerca "Xipper": Comprimi, Estrai e Verifica.

Le azioni dal Finder creano sempre file nuovi accanto agli originali (`nome.zip`, `nome 2`…) e non sovrascrivono mai nulla.

## Cosa provare

| Area | Prova | Cosa ti aspetti |
|---|---|---|
| Comprimere | Trascina file e cartelle nella finestra, cambia nome, cartella, formato e livello, poi **Comprimi** | Pannello con velocità e tempo stimato; a fine lavoro i riquadri con dimensione, tempo e velocità |
| Password | Con ZIP: **Password**, poi riapri l'archivio | Richiesta di password; con quella sbagliata compare "Password errata" |
| Aprire | Doppio clic su uno .zip / .tar.gz / .tar.zst / .tar.xz | Browser con cartelle, anteprima e dettagli |
| Estrarre | **Estrai** (accanto all'archivio), oppure seleziona voci, oppure ⌥ + **Estrai** | Lo sheet con destinazione, struttura e conflitti; "Mantieni entrambi" / "Sostituisci" (nel Cestino) / "Salta" |
| Verificare | **Verifica** nel browser o dal Finder | Esito "Integro" oppure l'elenco delle voci danneggiate |
| Annullare | Un archivio grande in **Massimo**, poi **Annulla** | Si ferma subito e non resta nessun file parziale |
| Disco pieno | Comprimi su una chiavetta quasi piena | "Spazio su disco esaurito", con **Riprova** / **Salva altrove…** |
| Genomica | Comprimi un `.vcf`: diventa `.vcf.gz` BGZF; poi `tabix -p vcf` | Indicizzabile da tabix / bcftools |
| Sicurezza | Apri uno zip scaricato da Internet ed estrai | I file estratti restano in quarantena (Gatekeeper li controlla) |
| Quick Look | Nel browser seleziona un'immagine o un PDF e premi la barra spaziatrice | Si apre l'anteprima; cambiando selezione cambia anche l'anteprima |
| Trascinare | Trascina un file o una cartella dal browser alla Scrivania | Il file viene estratto lì |
| Portachiavi | Apri uno ZIP cifrato, attiva "Ricorda nel Portachiavi", poi riaprilo | La seconda volta basta Touch ID |
| Notifiche e Dock | Avvia un lavoro lungo e passa a un'altra app | Barra di avanzamento sull'icona nel Dock e notifica alla fine |
| Assistenti AI | **Impostazioni › Integrazioni**: aggiungi una cartella, poi **Copia comando per Claude Code** | Claude Code vede il server "xipper" |

## Limiti noti della beta2
- **7z e RAR non sono supportati** (previsti più avanti). ZIP Deflate64 non è supportato. Gli ZIP divisi in parti (`.z01`…, `.zip.001`…) si aprono da qualsiasi parte.
- Gli **attributi estesi del Mac** (tag del Finder, resource fork) vengono salvati nei formati tar e riapplicati in estrazione, anche da ZIP del Finder e tar di macOS (`__MACOSX`, `._`). Negli ZIP creati da Xipper non vengono ancora salvati.
- **Solo italiano.**
- L'estensione del Finder legge solo i nomi dei file selezionati e passa la richiesta all'app; non legge il contenuto dei file.
- Le password salvate valgono per il percorso dell'archivio: se lo sposti, Xipper la chiede di nuovo.
- Mancano ancora: icona in Icon Composer, barra dei menu, cartelle sorvegliate.

## Segnalare un problema
Apri una issue su <https://github.com/nicolorisitano82/xipper/issues> indicando:
- versione di macOS e modello del Mac;
- cosa hai fatto, cosa ti aspettavi e cosa è successo;
- se possibile, un archivio di esempio (o come crearlo).

Per i problemi con gli assistenti AI allega le righe pertinenti di `~/Library/Logs/Xipper/mcp-audit.jsonl`. Non contiene password né il contenuto dei file.

## Aggiornamenti
Una volta al giorno Xipper chiede a GitHub se c'è una versione nuova; puoi farlo anche da **Xipper › Cerca aggiornamenti…**. Se c'è, ti chiede se scaricarla: l'immagine disco va nei **Download** e viene controllata con l'impronta SHA-256 del rilascio. Poi Xipper la apre e si chiude, e tu trascini Xipper in **Applicazioni** come la prima volta. Il controllo giornaliero si spegne in **Impostazioni › Generali › Aggiornamenti**.

## Privacy
Xipper non raccoglie dati. L'unico collegamento a Internet è la domanda a GitHub sugli aggiornamenti, che invia solo il nome e la versione dell'app; si può disattivare. Tutto il resto avviene sul tuo Mac.

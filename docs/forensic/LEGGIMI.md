# Xipper Forensic 0.9 — anteprima

*Italiano · [English](README.en.md)*

Xipper Forensic acquisisce, verifica e custodisce evidenze digitali in archivi **XIZ forensi**: ogni archivio porta l'hash di ogni blocco, l'hash della sorgente, i dati del caso e del reperto, la catena di custodia, tutto firmato. Fa parte della famiglia Xipper ma è un'app separata. Per Mac con Apple Silicon e **macOS 26 o successivo**. Gratuita, licenza MIT.

**Anteprima:** questa versione acquisisce **file e cartelle**, **file immagine** (.dd, .img, .raw…) e un **Mac in modalità «Condividi disco»** collegato in sola lettura. L'acquisizione diretta dei dischi (`/dev/rdiskN`, con blocco del montaggio) arriva con la 1.0. Prima di usarla in un incarico vero, provala su dati di prova e confronta gli hash con un altro strumento.

## Installazione
1. Apri il `.dmg` e trascina **Xipper Forensic** in **Applicazioni**.
2. **Primo avvio.** L'app è firmata con un certificato proprio, non con un Developer ID Apple, quindi macOS la blocca la prima volta: apri l'app, scegli **Fine**, poi in **Impostazioni di Sistema › Privacy e sicurezza** premi **Apri comunque**. In alternativa, da Terminale:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Xipper Forensic.app"
   ```

3. L'impronta SHA-256 del DMG è nel file `.sha256` che lo accompagna.

## Primi passi
1. **Impostazioni** (⌘,): il tuo nome di operatore e una **chiave di firma** (si crea lì e resta nel Portachiavi). Tutto quello che fai è firmato con questa chiave: consegna la chiave pubblica, mostrata sotto, a chi dovrà controllare le firme.
2. Facoltativo: un'**autorità di marcatura temporale** (RFC 3161). Senza, l'app lavora **offline**, non va mai in rete e il report lo dichiara.
3. **Nuovo caso…**: numero del caso, procedimento, autorità, luogo. Il caso è una cartella `.xfcase`.

## Acquisire un reperto
**Nuovo reperto…** apre una procedura in sei passi, sempre nello stesso ordine:
1. **Reperto:** numero (proposto R01, R02…), descrizione, modello, numero di serie, sigilli trovati.
2. **Sorgente:** file e cartelle, file immagine, oppure Mac via «Condividi disco». Per un Mac: avvialo in recoveryOS, scegli Utility › Condividi disco, collega i due Mac con un cavo o sulla stessa rete e inserisci l'indirizzo che mostra; l'app monta la condivisione in sola lettura e rifiuta un montaggio scrivibile.
3. **Opzioni:** MD5 e SHA-1 per compatibilità (SHA-256 sempre), compressione, attributi estesi, cifratura con password.
4. **Controlli:** ✔ superato, ⚠ avviso (si va avanti, resta nel registro), ⛔ blocco. Per avviare scrivi il tuo nome: controlli e conferma entrano nel registro del caso.
5. **Acquisizione:** avanzamento, pausa, interruzione con motivo. Il Mac non va in stop.
6. **Esito a tre stati:** completa · completa con avvisi (elementi non leggibili, elencati nell'inventario firmato) · non riuscita.

Alla fine nella cartella del reperto ci sono l'archivio `Rnn.xiz`, il report `Rnn.report.json` e il report stampabile `Rnn.report.pdf`, entrambi firmati (`.sig`).

**Riporta nel verbale lo SHA-256 dell'archivio**: è il riferimento esterno che rende evidente ogni modifica successiva.

## Custodia e verifica
- **Passaggio di mano…** aggiunge in coda all'archivio un segmento di custodia firmato (da chi, a chi, motivo, stato dei sigilli): il contenuto non cambia e le firme precedenti restano valide.
- **Verifica il caso** controlla la catena firmata del registro, i dati del caso e l'hash di ogni archivio e report.
- **Verifica un archivio…** apre qualsiasi `.xiz` forense, anche senza il suo caso: struttura, hash di ogni blocco, firme, marche temporali, hash della sorgente, e lo SHA-256 dal verbale se lo inserisci. Per questi controlli la password non serve.

## Per chi riceve l'evidenza
Chi riceve un archivio può verificarlo senza l'app:
- con la riga di comando inclusa: `"/Applications/Xipper Forensic.app/Contents/Helpers/xipper-forensic" verify R01.xiz --expect-sha256 <hash dal verbale>`;
- con `xiz forensic R01.xiz` di **libxiz**, un'implementazione indipendente del formato in C, compilabile anche su Linux e Windows (cartella `libxiz` del repository).

Il formato è documentato in `docs/XIZ_SPEC.md` §20.

## Limiti di questa anteprima
- Niente acquisizione diretta dei dischi: arriva con la 1.0, insieme all'helper che apre i dischi in sola lettura e blocca il montaggio.
- I dettagli tecnici dei controlli sono in inglese anche nel report italiano.
- XIZ rende evidente la manomissione, non la impedisce: togliere gli ultimi segmenti di custodia lascia un archivio valido. Per questo nel verbale vanno lo SHA-256 dell'archivio e il numero dei passaggi di mano.
- Solo Mac con Apple silicon, sia quello che acquisisce sia il Mac sorgente via «Condividi disco». I Mac Intel non sono supportati.

Segnalazioni: https://github.com/nicolorisitano82/xipper/issues

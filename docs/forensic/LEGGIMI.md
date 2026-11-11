# Xipper Forensic 1.0

*Italiano · [English](README.en.md)*

Xipper Forensic acquisisce, verifica e custodisce evidenze digitali in archivi **XIZ forensi**: ogni archivio porta l'hash di ogni blocco, l'hash della sorgente, i dati del caso e del reperto, la mappa dei settori illeggibili e la catena di custodia, tutto firmato. Fa parte della famiglia Xipper ma è un'app separata. Solo per Mac con **Apple silicon** e **macOS 26 o successivo**. Gratuita, licenza MIT.

Prima di usarla in un incarico, leggi il **documento di validazione** (`VALIDAZIONE.md`): dice cosa è stato provato, come, con quali risultati e cosa no. Puoi ripetere le prove sul tuo Mac con `scripts/forensic-validation.sh` dal repository.

## Installazione
1. Apri il `.dmg` e trascina **Xipper Forensic** in **Applicazioni**.
2. **Primo avvio.** L'app è firmata con un certificato proprio, non con un Developer ID Apple, quindi macOS la blocca la prima volta: apri l'app, scegli **Fine**, poi in **Impostazioni di Sistema › Privacy e sicurezza** premi **Apri comunque**. In alternativa, da Terminale:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Xipper Forensic.app"
   ```

3. L'impronta SHA-256 del DMG è nel file `.sha256` che lo accompagna.

## Primi passi
1. **Impostazioni** (⌘,):
   - il tuo nome di operatore;
   - come firmi: una **chiave Xipper** (si crea lì e resta nel Portachiavi) oppure un **certificato** dal Portachiavi o da una smart card (ECDSA P-256 o RSA), che lega la firma alla tua identità;
   - facoltativo: un'**autorità di marcatura temporale** (RFC 3161), anche con account, e il controllo delle marche sull'**elenco di fiducia UE** (Italia: AgID) per sapere se sono qualificate. Senza autorità l'app lavora **offline** e il report lo dichiara;
   - **Dischi**: installa l'**helper dei dischi** (vedi sotto) se devi acquisire dischi veri.
2. **Nuovo caso…**: numero del caso, procedimento, autorità, luogo. Il caso è una cartella `.xfcase`.

## L'helper dei dischi
I dischi appartengono al sistema: per leggerli serve un piccolo helper che gira come root e fa una sola cosa, aprire il disco **in sola lettura** e passarlo all'app. Non scrive mai. Due approvazioni, entrambe tue:
1. **Impostazioni › Dischi › Installa…**, poi consenti l'helper in **Impostazioni di Sistema › Generali › Elementi login ed estensioni**;
2. solo per i dischi **interni**: **Privacy e sicurezza › Accesso completo al disco**, aggiungi `xipper-forensic-helper`.

Le immagini disco collegate da te si leggono anche senza helper.

## Acquisire un reperto
**Nuovo reperto…** apre una procedura in sei passi, sempre nello stesso ordine:
1. **Reperto:** numero (R01, R02…), descrizione, modello, numero di serie, sigilli trovati.
2. **Sorgente:**
   - **Disco**: il disco intero o una partizione, letti settore per settore. Il disco di avvio e quello che contiene il caso sono esclusi; un disco interno chiede il numero di serie scritto a mano. Se possibile collega il reperto con un write blocker hardware;
   - **File e cartelle**: acquisizione logica con inventario firmato di tutto ciò che si trova, anche di ciò che non si legge;
   - **File immagine**: un'immagine raw (.dd, .img, .001…) o un **E01**, che viene importato controllando i suoi MD5 e SHA-1;
   - **Condividi disco**: un Mac avviato in recoveryOS con Utility › Condividi disco, montato in sola lettura.
3. **Opzioni:** MD5 e SHA-1 per compatibilità (SHA-256 sempre), **errori di lettura** (Rapido, Standard, Esaustivo), compressione, cifratura con password.
4. **Controlli:** ✔ superato, ⚠ avviso (resta nel registro), ⛔ blocco. Per avviare scrivi il tuo nome.
5. **Acquisizione:** avanzamento, **mappa del disco** con i settori illeggibili, pausa, interruzione con motivo. Durante la lettura macOS non può montare il disco; il Mac non va in stop.
6. **Esito a tre stati:** completa · completa con avvisi (settori illeggibili o elementi non letti, elencati e firmati) · non riuscita.

Alla fine nella cartella del reperto ci sono l'archivio `Rnn.xiz` e i report `Rnn.report.json` e `Rnn.report.pdf`, firmati (`.sig`).

**Riporta nel verbale lo SHA-256 dell'archivio**: è il riferimento esterno che rende evidente ogni modifica successiva.

## Custodia, consegna, esportazione
- **Passaggio di mano…** aggiunge in coda all'archivio un segmento di custodia firmato: il contenuto non cambia e le firme precedenti restano valide.
- **Consegna una copia…** prepara una copia per qualcuno, in una cartella sua con una **ricevuta firmata**; l'originale registra il passaggio di mano. Formati: un nuovo XIZ per la chiave pubblica del destinatario o per una password, l'immagine raw con i suoi hash, E01, oppure solo alcuni file di un'acquisizione logica, ciascuno con la prova che appartiene all'archivio firmato.
- **Esporta** un'immagine in raw o in **E01** (segmenti da 1,5 GB con i dati del caso, MD5 e SHA-1; verificato con `ewfverify` e The Sleuth Kit).
- **Verifica il caso** e **Verifica un archivio…** controllano registro, firme, certificati, marche, hash della sorgente e lo SHA-256 dal verbale.

## Per chi riceve l'evidenza
Chi riceve un archivio può verificarlo senza l'app e senza un Mac, con **xiz** (libxiz, un'implementazione indipendente del formato in C), pubblicato con questa versione per **Linux, Windows e macOS**:

```bash
xiz forensic R01.xiz
xiz cat R01.xiz image.dd | sha256sum
```

Il formato è documentato in `docs/XIZ_SPEC.md` §20 del repository.

## Limiti
- XIZ rende evidente la manomissione, non la impedisce: togliere gli ultimi segmenti di custodia lascia un archivio valido. Per questo nel verbale vanno lo SHA-256 dell'archivio e il numero dei passaggi di mano.
- Settori illeggibili, smart card e TSA qualificate sono provati come descritto nel documento di validazione: leggilo prima di un incarico.
- L'elenco di fiducia UE è letto via https; la sua firma XML non è verificata da questa versione (il report ne riporta lo SHA-256).
- I dettagli tecnici dei controlli sono in inglese anche nel report italiano.
- Solo Mac con Apple silicon, sia quello che acquisisce sia il Mac sorgente via «Condividi disco». I Mac Intel non sono supportati.

Segnalazioni: https://github.com/nicolorisitano82/xipper/issues

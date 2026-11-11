# Xipper Forensic 1.0 — documento di validazione

Questo documento dice **cosa fa** Xipper Forensic 1.0, **come è stato provato** e **con quali risultati**, e
soprattutto **cosa non è stato provato**. Segue l'impostazione del programma NIST CFTT (Computer Forensics
Tool Testing): requisiti dello strumento, asserzioni verificabili, casi di prova con dati noti, risultati
riproducibili. Non è una certificazione NIST né di un ente terzo: è la validazione del produttore, pubblicata
con gli script che permettono a chiunque di ripeterla.

## 1. Oggetto

| | |
|---|---|
| Strumento | Xipper Forensic 1.0.0 (app, CLI `xipper-forensic`, helper dei dischi) e il lettore indipendente `xiz` (libxiz) |
| Formato | XIZ 1.10, profilo forense (`docs/XIZ_SPEC.md` §20), firme §13.5 |
| Ambiente | Mac con Apple silicon, macOS 26 o successivo |
| Codice | https://github.com/nicolorisitano82/xipper, commit indicato nel risultato dell'esecuzione (§5) |

Funzioni sotto prova: acquisizione fisica di dischi e partizioni, di file immagine ed E01, acquisizione
logica; calcolo degli hash; gestione dei settori illeggibili; blocco del montaggio; firma, catena dei segmenti
e custodia; registro del caso e report; esportazione raw ed E01; consegna; verifica indipendente.

## 2. Requisiti

Ispirati alle specifiche CFTT per l'acquisizione di dati digitali (requisiti obbligatori e facoltativi
dello strumento di imaging) e adattati a un formato con firme. La numerazione è propria di questo documento.

| # | Requisito |
|---|---|
| R1 | Lo strumento acquisisce tutti i settori visibili della sorgente (disco intero o partizione) |
| R2 | I dati acquisiti sono esatti: l'immagine nell'archivio è identica, byte per byte, alla sorgente |
| R3 | Gli hash (SHA-256, e a richiesta MD5 e SHA-1) sono quelli che strumenti standard calcolano sulla sorgente |
| R4 | Errori di lettura non risolti: l'utente è avvisato del tipo e della posizione; al posto dei dati illeggibili c'è un riempimento neutro (zeri), documentato |
| R5 | La sorgente non viene modificata: il disco è aperto in sola lettura, macOS non lo monta durante la lettura |
| R6 | Le sorgenti pericolose sono escluse o confermate: disco di avvio e disco di destinazione rifiutati, disco interno solo con il seriale scritto a mano |
| R7 | Ogni modifica successiva dell'archivio, del registro o dei report è rilevata |
| R8 | La catena di custodia è registrata e verificabile senza la chiave del contenuto |
| R9 | L'archivio è verificabile da un'implementazione indipendente, senza lo strumento che l'ha prodotto |
| R10 | Le esportazioni (raw, E01) e le importazioni (E01) conservano i dati e gli hash, e sono lette da strumenti terzi |
| R11 | L'acquisizione logica elenca tutto ciò che trova, anche ciò che non legge, in un inventario firmato |
| R12 | Firme con certificato e marche temporali: verificate e descritte (firmatario, validità, stato qualificato) |

## 3. Casi di prova

Eseguiti da `scripts/forensic-validation.sh` (dati sintetici e immagini disco create sul momento; le
immagini NIST CFReDS se si passa la cartella dei download). Ogni caso scrive il suo registro in
`dist/validation-VERSIONE/logs/`.

| Caso | Requisiti | Cosa fa | Atteso |
|---|---|---|---|
| V01 | R2, R3 | 16 sorgenti sintetiche da 0 byte a 13 MiB intorno al confine dei blocchi da 4 MiB (vuote, zeri, casuali); acquisizione; rilettura con xipper e con libxiz | SHA-256, SHA-1, MD5 uguali a `shasum`/`md5`; immagine riletta identica |
| V02 | R1, R2, R3, R9 | Immagine disco FAT32 da 48 MiB collegata senza montarla; `acquire --device diskN` | SHA-256 dell'archivio = `shasum /dev/rdiskN`; `xiz forensic` riuscito; esportazione raw identica |
| V03 | R1, R2 | Come V02 sulla sola partizione | SHA-256 = `shasum /dev/rdiskNs1`; offset della partizione nel record |
| V04 | R5, R6 | Disco con volume montato senza e con `--unmount`; disco di avvio | Rifiuto senza `--unmount`; volume smontato e acquisito con; disco di avvio rifiutato |
| V05 | R5 | Blocco del montaggio (Disk Arbitration) mentre il disco è aperto | `diskutil mount` rifiutato durante, permesso dopo; lettura identica |
| V06 | R4 | Errori di lettura simulati: settore singolo, tre settori a cavallo di due blocchi, settore che si riprende alla terza lettura, preset Rapido, sorgente che sparisce (`ENXIO`) | Intervalli esatti con errno e tentativi; zeri; hash coerenti; verifica superata con avviso; sorgente sparita = acquisizione fermata, niente archivio |
| V07 | R11, R9 | Cartella con file, link, FIFO e un file illeggibile (`chmod 000`) | Inventario firmato con tutti gli elementi, «2 non acquisiti»; verifica xipper e libxiz |
| V08 | R7, R9 | Un byte cambiato in tre punti dell'archivio (inizio, dati, fine); archivio troncato al segmento precedente | Ogni modifica rilevata da xipper e da libxiz; troncatura rilevata con lo SHA-256 del verbale |
| V09 | R8, R9 | Archivio cifrato con password; cinque passaggi di mano aggiunti senza password | Sei segmenti firmati, catena integra, letta anche da libxiz |
| V10 | R7 | Registro del caso con una riga cambiata; report PDF sostituito | Entrambi rilevati da `case verify`; firma del report valida sull'originale |
| V11 | R10 | E01 esportato (anche in segmenti, con settori illeggibili); E01 di libewf importato | `ewfverify` riuscito; error2 letto da libewf; `fls` uguale su E01 e raw; hash dell'import uguali |
| V12 | R12, R7, R10 | Test automatici: firme con certificato EC e RSA (anche libxiz), elenco di fiducia nel tempo, consegne, E01, casi e report | Tutti superati |
| V13 | R9 | Test di libxiz: unità, vettori scritti da Swift, input ostili | Tutti superati |
| V14 | R2, R3 | Immagini NIST CFReDS (Rhino Hunt, Basic Mac, Data Leakage RM#3 e RM#2) | MD5 e SHA-1 uguali a quelli pubblicati da NIST |

## 4. Prove a mano

| Prova | Data | Esito |
|---|---|---|
| Helper dei dischi installato e approvato (Elementi login), acquisizione di una chiavetta USB dall'app | 11/11/2026 | regolare (proprietario) |
| Procedura guidata completa su file, cartelle e immagini; verifica, custodia, report PDF | 10/11/2026 | regolare (proprietario); un difetto trovato e corretto (chiave nuova non riconosciuta fino al riavvio) |
| Lettura dell'elenco di fiducia italiano reale (AgID) | 11/11/2026 | 47 servizi QTST, 31 attivi |

## 5. Risultati

Esecuzione dell'11/11/2026 su MacBook Pro (Mac15,10, Apple M3 Max), macOS 27.3 (26C5035r), Swift 6.4,
libewf 20140817, The Sleuth Kit 4.15.0. Il file completo con i registri è `RESULTS.md` (allegato al
rilascio); il commit è quello del tag `forensic-v1.0.0`.

| Caso | Esito | Asserzione verificata |
|---|---|---|
| V01 | ✔ | SHA-256, SHA-1 e MD5 uguali a `shasum`/`md5` su 16 sorgenti; immagine riletta identica da xipper e libxiz |
| V02 | ✔ | Disco intero: SHA-256 dell'immagine = `shasum /dev/rdiskN`; libxiz verifica; export raw identico |
| V03 | ✔ | Partizione: SHA-256 = `shasum /dev/rdiskNs1`; offset registrato |
| V04 | ✔ | Volume montato rifiutato senza `--unmount`, smontato e acquisito con; destinazione sul disco sorgente e disco di avvio rifiutati |
| V05 | ✔ | Montaggio rifiutato durante la lettura, permesso dopo |
| V06 | ✔ | Settori illeggibili simulati: intervalli esatti, zeri, mappa con errno e tentativi; sorgente sparita = acquisizione fermata |
| V07 | ✔ | Acquisizione logica: tutti gli elementi nell'inventario firmato, 2 non acquisiti (file illeggibile, FIFO) e dichiarati |
| V08 | ✔ | Un byte cambiato in tre punti: rilevato da xipper e libxiz; troncatura rilevata con lo SHA-256 del verbale |
| V09 | ✔ | Cinque passaggi di mano senza password su archivio cifrato; sei firme in catena, anche per libxiz |
| V10 | ✔ | Riga del registro cambiata e report sostituito: rilevati |
| V11 | ✔ | E01: `ewfverify` riuscito (anche a segmenti, con error2), `fls` uguale a raw, E01 di libewf importato con hash uguali |
| V12 | ✔ | Firme con certificato EC e RSA, elenco di fiducia, consegne, E01, casi e report: test superati |
| V13 | ✔ | Test di libxiz superati |
| V14 | — | Non eseguito in questa sessione (immagini non presenti). Ultima esecuzione: 10/11/2026 (P2), 4 immagini CFReDS, MD5 e SHA-1 uguali a quelli di NIST |

**13 casi superati su 13 eseguiti.** Durante la preparazione la validazione ha trovato un difetto, corretto
prima del rilascio: il campo «SHA-256 dal verbale» accettava solo lo SHA-256 dell'immagine, mentre l'app
chiede di riportare nel verbale quello dell'archivio. Ora accetta lo SHA-256 del file archivio com'era alla
fine di qualunque segmento (all'acquisizione o a un passaggio di mano) oppure quello dell'immagine, e un
archivio tagliato dopo il passaggio di mano annotato risulta non valido.

## 6. Non provato, e cosa significa

| Funzione | Stato | Conseguenza per chi la usa |
|---|---|---|
| Disco con settori **davvero** illeggibili | provato solo con errori simulati (V06) | prima di un incarico su un supporto danneggiato, provare su un disco difettoso noto; il comportamento atteso è quello di V06 |
| Disco interno di un Mac tramite helper con Accesso completo al disco | non provato | seguire la procedura dell'helper; il disco di avvio è comunque escluso |
| HPA/DCO (aree nascoste dei dischi ATA) | non gestite | il disco viene letto per la dimensione che macOS espone; aree nascoste non sono acquisite né segnalate |
| Smart card reale (PIV o carta di firma italiana) | provato con chiavi in memoria e certificati di prova | provare la carta con «Prova il certificato» nelle Impostazioni prima dell'uso |
| TSA qualificata con account | non provata (servono credenziali) | provare con un archivio di prova; il report dice se la marca è qualificata |
| «Condividi disco» da un secondo Mac | non provato | usare l'acquisizione logica con montaggio in sola lettura, verificandone il messaggio |
| Data Leakage PC (21 GB) di CFReDS | non provato per spazio | — |
| Firma XML dell'elenco di fiducia UE | non verificata dallo strumento | il report riporta lo SHA-256 dell'elenco usato, confrontabile con quello pubblicato |
| Revoca dei certificati (firmatari e TSA) | non controllata | controllarla a parte se il procedimento lo richiede |

## 7. Come ripetere

```bash
git clone https://github.com/nicolorisitano82/xipper && cd xipper
brew install cmake libewf sleuthkit
scripts/forensic-validation.sh                    # tutti i casi tranne CFReDS
scripts/forensic-validation.sh ~/Downloads/cfreds  # con le immagini NIST CFReDS scaricate
```

Il risultato è in `dist/validation-VERSIONE/RESULTS.md`, con i registri di ogni caso. Uno strumento validato
resta valido per la versione e l'ambiente provati: dopo un aggiornamento di macOS o dello strumento, ripetere
l'esecuzione.

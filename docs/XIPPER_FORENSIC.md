# xipper-forensic: studio del prodotto, dell'interfaccia e delle funzioni

Stato: **studio con decisioni prese** (§6), 10/11/2026, branch `forensic`. Nessuna riga di codice.
Completa [FORENSE_3.1.md](FORENSE_3.1.md), che resta il riferimento per formato, norme e acquisizione a basso
livello. Qui: che prodotto è, come è fatto, che faccia ha, cosa fa e in che ordine si costruisce.
Note della ricerca sui concorrenti: [research_notes/forensic_tools_ui.md](research_notes/forensic_tools_ui.md).

Convenzioni: **[Fatto]** verificato nel codice o in una fonte citata; **[Proposta]** idea da decidere;
**[Da verificare]** da controllare prima di citarla all'esterno.

---

## 1. Il prodotto

### 1.1 Cosa è

**[Proposta]** xipper-forensic è un'app macOS per **acquisire, sigillare, verificare e consegnare**
evidenze digitali. Fa una cosa sola e la fa in modo che un terzo possa ricontrollarla:

```
  identifica ──► acquisisci ──► verifica ──► sigilla ──► custodisci ──► consegna
  (caso,          (disco,        (rilettura,  (firma,     (passaggi di  (copia per
   reperto,        volume,        hash,        marca       mano firmati) destinatario,
   dispositivo)    cartelle)      report)      temporale)                 export E01/raw)
```

Non è uno strumento di **analisi** (timeline, carving, ricerca per parole chiave, parsing di artefatti).
Quello lo fanno Autopsy, X-Ways, AXIOM, EnCase. xipper-forensic produce l'evidenza che quegli strumenti
leggono (raw/E01 esportato o montato) e ne custodisce la storia. Questa scelta tiene il prodotto piccolo,
verificabile e difendibile in un controesame.

### 1.2 Per chi

| Utente | Cosa gli serve | Cosa lo fa scegliere xipper-forensic |
|---|---|---|
| Consulente tecnico (CTU, CTP, consulente del PM) | acquisire in sopralluogo, con verbale, spesso su un Mac | Mac nativo, report pronto per il verbale, firma e marca |
| Polizia giudiziaria, laboratori | volumi alti, procedure ripetibili, custodia | catena di custodia firmata dentro il file, verifica senza password |
| Studi legali, e-discovery aziendale | raccolta logica (cartelle, mail), consegna parziale | consegna per destinatario, prova di un singolo file |
| IT aziendale / incident response | copia rapida di un disco o di cartelle prima di toccare nulla | semplicità, nessuna licenza costosa |
| Chi riceve l'evidenza (giudice, avvocato, controparte) | controllare che il file sia integro | verificatore gratuito, anche senza la chiave per leggere il contenuto |

### 1.3 Rapporto con Xipper

**[Fatto]** Decisione del 10/11/2026: prodotto derivato e separato, famiglia Xipper. L'app Xipper non mostra
funzioni forensi.

**[Proposta]** Cosa si condivide e cosa no:

| Livello | Condiviso con Xipper | Solo xipper-forensic |
|---|---|---|
| Formato | XIZ, con il profilo forense (bit `forensic`) | — |
| Codice | XipperKit (scrittura/lettura XIZ, firme, marche, prove, recovery record, Portachiavi) | `ForensicKit`: dispositivi, acquisizione, caso, custodia, report, export E01 |
| Lettore indipendente | libxiz (C99, già esistente) | `xizcat` e verificatore da riga di comando costruiti su libxiz |
| App | — | app propria, icona propria, bundle id proprio, DMG proprio |
| Riga di comando | — | `xipper-forensic` (o `xfor`), separata da `xipper` |
| Rilascio | stesso repository, stesso ciclo di test | versione propria (1.0, 1.1…), release GitHub con prefisso `forensic-v` |

Motivo della CLI separata: chi scrive un verbale cita uno strumento e una versione. «xipper-forensic 1.0.2»
è più chiaro di «xipper 3.1.4, comando acquire», e la versione del forense non deve cambiare quando Xipper
aggiunge un codec.

### 1.4 Concorrenti e spazio libero

Sintesi delle note di ricerca (fonti [Rn] in [research_notes/forensic_tools_ui.md](research_notes/forensic_tools_ui.md)).

| Strumento | Piattaforma, prezzo | Forza | Debolezza per chi usa un Mac |
|---|---|---|---|
| FTK Imager 8.3 (Exterro) | Windows; Pro 499 $/anno | standard di fatto, procedura guidata semplice | niente versione Mac nativa; verifica sequenziale lenta |
| Guymager | Linux, gratuito | rilettura anche della sorgente, file `.info` con smartctl | configurazione nascosta in file `.cfg`; non gira su Mac |
| Cellebrite Digital Collector 3.9 | SSD USB dedicato, prezzo non pubblico | immagini APFS decifrate di Mac M1–M4, AFF4, albero decisionale per i Mac | costoso; si rompe con gli aggiornamenti di macOS; legato a hardware |
| SUMURI RECON ITR | SSD dedicato, da 1.295 $/anno (smette di funzionare a scadenza) | M1–M6, macOS 27, triage per gravità, snapshot APFS | abbonamento; immagine, non catena di custodia |
| Fuji | gratuito (GPL-3), Python | acquisizione logica live con ASR/rsync in DMG | essenziale: niente caso, niente firma, niente report |
| OpenText TX1/TX2 | hardware | controlli prima dell'avvio (avvisi e blocchi), pausa/ripresa, TX2: hash ad albero e verifica parallela | hardware costoso, non acquisisce Mac Apple Silicon |
| Atola TaskForce | hardware | settori danneggiati: più passate, lettura inversa, mappa del disco, file colpiti | idem |

**[Fatto, dalle note]** Cosa manca a tutti, e quindi è lo spazio di xipper-forensic:

1. **Nessuno firma l'evidenza con l'identità dell'operatore.** La custodia è un log di testo o HTML [R1][R30].
2. **Nessuno strumento Mac nativo moderno, gratuito o economico**: per i Mac si usa hardware dedicato in
   abbonamento o script [R21][R28][R51][R53].
3. **La verifica raddoppia i tempi** e scopre l'errore solo alla fine; solo il TX2 hardware verifica a blocchi in
   parallelo [R31][R58]. XIZ ha già frame indipendenti: la tabella hash dei frame con radice Merkle dà la stessa
   cosa in software.
4. **Settori illeggibili riempiti di zeri con esito «riuscito»** ambiguo [R15][R30].
5. **Apple Silicon confonde**: niente Target Disk Mode, «Condividi disco» solo a livello di file e montato in
   scrittura dal Finder, Secure Boot da abbassare e poi ripristinare con Wi-Fi senza che resti scritto da
   nessuna parte [R49][R51][R55].
6. **Report sparsi** in più file di formati diversi accanto all'immagine [R1][R12][R30].

Conseguenza: **la realtà del Mac moderno è l'acquisizione logica**. «Physical imaging of modern Macs is pretty
much dead» [R55]. La 1.0 deve essere eccellente sull'acquisizione logica e sulla custodia; la fisica serve per
dischi esterni, chiavette, Mac Intel e dischi estratti.

---

## 2. Stato di partenza

Lo studio FORENSE_3.1.md è stato scritto su XIZ 1.4. Da allora alcune lacune si sono chiuse.

| Lacuna nello studio del 02/11 | Oggi [Fatto] |
|---|---|
| Lettore indipendente assente (alta) | **libxiz** in C99, scritto dalla spec: legge fino alla 1.8, verifica firme e prove, ripara con il recovery record. Mancano: verifica RFC 3161, lettura 1.9 |
| Correzione degli errori solo esterna (media) | **Recovery record interno** (XIZ 1.5, §15), anche riparazione in place, anche in libxiz |
| Firme solo Ed25519 classiche | identità **post-quantum X-Wing** per i destinatari (1.7); firme ancora Ed25519 |
| Storia dell'archivio | **Versioni** (3.0): ogni segmento si apre in sola lettura com'era |

Restano aperte (dettagli in FORENSE_3.1.md §3 e §7):

1. metadati forensi: voce `image`, record del caso e del dispositivo, log, hash della sorgente, mappa dei settori;
2. identità del firmatario: certificato X.509, smart card, TSA con autenticazione;
3. hash crittografico dei frame per le letture casuali;
4. acquisizione da dispositivo (`/dev/rdiskN`, IOKit, Disk Arbitration, helper privilegiato);
5. export E01, montaggio forzato in sola lettura, report PDF.

---

## 3. Architettura

### 3.1 Componenti

```
 ┌──────────────────────────── XipperForensic.app ─────────────────────────────┐
 │  SwiftUI: casi, reperti, acquisizione, verifica, custodia, consegna          │
 │      │                                                                       │
 │      ▼                                                                       │
 │  ForensicKit (Swift package, dipende da XipperKit)                           │
 │   • Case/Evidence store (cartella del caso, JSON firmati)                     │
 │   • DeviceMonitor (Disk Arbitration + IOKit)                                  │
 │   • Acquirer (pipeline lettura → hash → frame → XIZ)                          │
 │   • Custody, Report (JSON + PDF), Export (raw, E01)                           │
 │      │ XPC                                                                   │
 │      ▼                                                                       │
 │  xipper-forensic-helper (LaunchDaemon via SMAppService, root)                │
 │   • apre /dev/rdiskN in sola lettura e passa il descrittore all'app           │
 │   • blocca il montaggio dei dischi in acquisizione (Disk Arbitration)         │
 └──────────────────────────────────────────────────────────────────────────────┘
 xipper-forensic (CLI, stesso ForensicKit; da usare con sudo senza helper)
 xizcat / xiz-verify (libxiz, C99, multipiattaforma) — per chi riceve l'evidenza
```

**[Proposta]** L'helper fa il minimo: apre il dispositivo `O_RDONLY` e restituisce il file descriptor via XPC
(i descrittori passano tra processi), più il veto ai montaggi. Tutta la logica resta nell'app, non privilegiata.
Superficie di attacco piccola, facile da spiegare in un controesame («il processo root non scrive mai»).

**[Fatto, prova del 10/11/2026 su macOS 27.2, `spike/forensic-helper/`]** `SMAppService.daemon` funziona con la
firma self-signed «Xipper Self-Signed», senza Developer ID e con l'app fuori da `/Applications`:

| Passo | Esito |
|---|---|
| `register()` | lancia «Operation not permitted» e lo stato diventa `requiresApproval`: è il comportamento normale, l'app deve trattarlo come «serve l'approvazione», non come un errore |
| Approvazione in Impostazioni › Generali › Elementi login (`SMAppService.openSystemSettingsLoginItems()`) | stato `enabled`, helper avviato da launchd come root |
| Helper apre `/dev/rdiskN` `O_RDONLY` e passa il descrittore via XPC (`xpc_dictionary_set_fd`) | l'app, utente normale, legge con quel descrittore; SHA-256 identico alla lettura diretta |
| Scrittura sul descrittore ricevuto | rifiutata (`EBADF`) |
| Percorsi diversi da `/dev/rdiskN[sM]` | rifiutati dall'helper |
| Client firmato in modo diverso (ad hoc) | rifiutato: `xpc_connection_set_peer_code_signing_requirement` con `certificate leaf = H"…"` (con una firma self-signed non c'è un'ancora Apple da citare) |
| Disco interno `/dev/rdisk0` (root:operator) | **«Operation not permitted» anche da root** finché l'helper non ha **Accesso completo al disco** (TCC); concesso a mano, funziona subito, senza riavviare l'helper |

Conseguenze per l'onboarding: **due** approvazioni manuali dell'utente, entrambe da spiegare passo passo
(l'app non può farle da sola): «Consenti in background» per l'helper e Accesso completo al disco per l'helper
(non per l'app). Il ripiego CLI con `sudo` resta, con lo stesso requisito TCC per il Terminale.

**[Da verificare]**: se una nuova build (firma uguale, binario diverso) richiede di nuovo le due approvazioni;
se i dischi esterni root:operator richiedono anch'essi Accesso completo al disco (le immagini disco collegate
dall'utente sono sue e si aprono anche senza helper).

### 3.2 La cartella del caso

**[Proposta]** Un caso è una cartella `NomeCaso.xfcase/` (pacchetto, si apre come documento):

```
Caso 2026-117.xfcase/
  case.json                 dati del caso (firmati a ogni modifica, storia in case.log)
  case.log                  JSON Lines append-only: ogni azione dell'operatore, firmata a catena
  evidence/
    R01 - MacBook Pro/
      R01.xiz               l'acquisizione (profilo forense)
      R01.report.pdf        report generato dal JSON dentro l'XIZ
      R01.report.json
      photos/               foto del reperto (sigilli, etichette, numero di serie)
    R02 - Chiavetta USB/
  deliveries/               copie consegnate (per destinatario), con ricevuta
```

L'XIZ è autosufficiente: dentro ci sono già caso, dispositivo, log e hash. La cartella del caso è
l'ambiente di lavoro e l'indice; se si perde, gli XIZ restano validi.

### 3.3 Privilegi e permessi di macOS

| Cosa | Perché | Come |
|---|---|---|
| root | leggere `/dev/rdiskN` | helper (§3.1) o `sudo` sulla CLI |
| Accesso completo al disco (TCC) | acquisizione logica di cartelle protette (Mail, Messaggi, Library) | richiesto all'app, con spiegazione nell'onboarding |
| Disk Arbitration | impedire il montaggio automatico del reperto | callback di approvazione nell'helper |
| Rete | solo marca temporale e (facoltativo) aggiornamenti | dichiarato nel report; modalità **offline** che la disattiva |

---

## 4. Interfaccia

### 4.1 Principi

1. **Il caso al centro, non il file.** Si apre un caso, non un archivio. Ogni reperto vive nel suo caso.
2. **Una procedura guidata, non una cassetta degli attrezzi.** L'acquisizione è una sequenza di passi con un
   ordine fisso: non si arriva a «Avvia» senza caso, reperto, sorgente e destinazione controllati.
3. **Niente di distruttivo, e lo si vede.** Nessun pulsante scrive sul reperto. Lo stato «sorgente protetta»
   è sempre visibile (badge in alto, colore). Le azioni irreversibili sulla destinazione (sovrascrivere un file)
   non esistono: i nomi sono generati e unici.
4. **Tutto è registrato.** Ogni clic che cambia qualcosa entra nel log del caso con ora UTC e monotona.
   L'utente può aggiungere note in ogni momento; le note entrano nel log, non sostituiscono nulla.
5. **Esito per punto, mai un solo «OK».** Verifica e report elencano ogni controllo con il suo risultato.
6. **Pensata per il sopralluogo.** Testo grande, contrasto alto, funziona con un Mac portatile su un tavolo
   non suo: niente popup a sorpresa durante l'acquisizione, notifiche solo a fine lavoro o su errore,
   `caffeinate` automatico, avviso se il Mac va a batteria.
7. **Stampabile.** Ogni schermata di riepilogo ha un'anteprima di stampa in A4: è quella che finisce allegata
   al verbale.

### 4.2 Finestra principale

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Caso 2026-117 · Proc. pen. 4471/26 R.G.N.R.        [🔒 Sorgenti protette] │
├──────────────────┬────────────────────────────────────────────────────────────────┤
│ CASO             │  R01 · MacBook Pro 14" (SN C02XXXXXX)                          │
│  Riepilogo       │  ─────────────────────────────────────────────────────────────  │
│  Registro        │  Stato      ✔ acquisito  ✔ verificato  ✔ firmato  ✔ marcato   │
│ REPERTI          │  Tipo       logica (recoveryOS · Condividi disco)              │
│  R01 MacBook ✔   │  Dimensione 412,6 GB → 301,2 GB (XIZ)                          │
│  R02 Chiavetta ⟳ │  SHA-256    4f1c…  [copia]  MD5 9a0e…                          │
│  R03 Disco est.  │  Firmato da Mario Rossi (cert. InfoCert) 10/11/2026 14:02 UTC  │
│ DISPOSITIVI      │                                                                │
│  disk4 SanDisk ⛔│  [Custodia]  [Verifica di nuovo]  [Report]  [Consegna…]        │
│  disk5 Samsung   │                                                                │
│                  │  Cronologia ─────────────────────────────────────────────────  │
│ [+ Reperto]      │  14:02  Firmato e marcato (TSA InfoCert)                       │
│                  │  13:58  Verifica completa: 6/6 controlli superati              │
│                  │  11:20  Acquisizione avviata da Mario Rossi                    │
└──────────────────┴────────────────────────────────────────────────────────────────┘
```

- Barra laterale in tre sezioni: **Caso**, **Reperti**, **Dispositivi** (collegati ora, con stato di protezione:
  ⛔ montaggio bloccato, ⚠ montato in scrittura).
- Area principale: scheda del reperto con lo **stato a tappe** (acquisito, verificato, firmato, marcato,
  consegnato) sempre in alto.
- Il badge **Sorgenti protette** in barra del titolo è verde solo se nessun dispositivo collegato in
  acquisizione è montato.

### 4.3 Procedura di acquisizione

| Passo | Contenuto | Controlli prima di andare avanti |
|---|---|---|
| 1. Reperto | numero (proposto R01, R02…), descrizione, foto (fotocamera del Mac o iPhone con Continuity Camera), sigilli trovati | numero unico nel caso |
| 2. Sorgente | schede **Disco**, **Volume**, **Cartelle e file**, **Mac via «Condividi disco»**: modello, seriale, capacità, interfaccia, bridge USB, schema partizioni, FileVault/cifratura, SMART, snapshot APFS | sorgente non montata (o smontata ora, con evento nel log); disco di avvio e destinazione esclusi; disco interno solo con conferma digitando il seriale [R11] |
| 3. Assistente Mac (solo se la sorgente è un Mac) | domande: acceso o spento? Intel o Apple Silicon? FileVault? credenziali disponibili? → metodo proposto (live logica, «Condividi disco», TDM sui Mac Intel). Ogni cambiamento allo stato del Mac (Secure Boot, SIP, sblocco FileVault) è chiesto come dichiarazione e **finisce nel log** [R24][R55] | metodo coerente con la sorgente |
| 4. Destinazioni | una o più (copia master e copia di lavoro in parallelo [R30]), spazio libero contro dimensione stimata, file system (avviso su FAT32), cifratura dell'XIZ (password o destinatari), divisione in parti, nome generato da caso + reperto + seriale + data | spazio sufficiente; destinazione ≠ sorgente |
| 5. Opzioni | hash (SHA-256 sempre; MD5 e SHA-1 per compatibilità), compressione (veloce/nessuna), errori di lettura con tre preset **Rapido / Standard / Esaustivo** (riletture e granularità [R30][R34]), seconda lettura della sorgente, snapshot APFS, recovery record, firma e marca | identità di firma sbloccata; TSA raggiungibile o modalità offline dichiarata |
| 6. Controlli e riepilogo | elenco di controlli automatici come il TX1: ✔ superato, ⚠ avviso (si può andare avanti, resta nel log), ⛔ blocco [R30]; poi tutto in una pagina stampabile, l'operatore conferma con il nome | nessun ⛔ |
| 7. Acquisizione | avanzamento (§4.4) | — |
| 8. Verifica | hash dei frame verificati in parallelo **durante** la scrittura (fallisce subito, non a fine lavoro), poi rilettura dell'XIZ e confronto con l'hash della sorgente; esito per punto | automatica, non saltabile |
| 9. Sigillo | firma del segmento, marca temporale, report PDF/JSON dentro l'XIZ e accanto | — |

Esito finale **a tre stati**, mai un «riuscito» ambiguo: ✔ completa · ⚠ completa con N settori illeggibili
(mappa e, per l'acquisizione di un volume, elenco dei file colpiti) · ✖ non riuscita.

**Profili di laboratorio** [R12]: le scelte dei passi 4–5 si salvano con un nome («Procura», «Aziendale»,
«Sopralluogo offline») invece che in file di configurazione nascosti.

### 4.4 Avanzamento

```
 R02 · Chiavetta SanDisk 64 GB  —  acquisizione fisica
 ████████████████████░░░░░░░░░░░  63%   40,3 / 64,0 GB
 Lettura 412 MB/s   Scrittura 298 MB/s   Rimangono ~1 min
 Settori illeggibili: 0          Riletture: 0
 SHA-256  in corso   MD5  in corso
 [mappa del disco: barre verdi lette, rosse illeggibili, grigie da leggere]
                                                     [Pausa]  [Interrompi…]
```

- Mappa del disco come gli strumenti hardware (Atola, Tableau): l'errore si vede **dove** è.
- Pausa e ripresa: l'acquisizione scrive segmenti firmati periodici (FORENSE_3.1 §4.2, checkpoint), quindi un
  distacco del cavo non fa ripartire da zero.
- **Interrompi** chiede il motivo, che entra nel log; il file parziale resta, marcato «incompleto».

### 4.5 Verifica

Si apre su qualunque `.xiz` forense, anche senza caso (doppio clic). Pensata anche per chi riceve:

```
 Verifica di R01.xiz                                              [Stampa] [Esporta JSON]
 ✔ Struttura del file e recovery record (0 blocchi danneggiati)
 ✔ Hash di ogni frame (98 304 / 98 304)
 ✔ SHA-256 del flusso = hash della sorgente registrato in acquisizione
 ✔ Firma di 3 segmenti, catena integra
 ✔ Marca temporale InfoCert del 10/11/2026 14:02 UTC (certificato qualificato)
 ✔ Hash atteso dal verbale: 4f1c… (inserito a mano)
 ⓘ Firmatario: Mario Rossi — certificato rilasciato da InfoCert, valido
 ⓘ 2 settori illeggibili riempiti di zeri (mappa allegata)
```

- Campo **«Hash dal verbale»**: il riferimento esterno che chiude troncatura e rifirma (FORENSE_3.1 §3.4).
- Non serve la password per verificare struttura, firme e hash della sorgente; serve per il contenuto.

### 4.6 Custodia

Linea del tempo del reperto: acquisizione, verifiche, passaggi di mano, consegne, aperture.
Un **passaggio di mano** è un modulo breve (da chi, a chi, motivo, stato dei sigilli, foto) che diventa un
segmento di custodia firmato in coda all'XIZ. Se chi riceve ha xipper-forensic, firma la ricezione: la
catena ha le firme di entrambi.

### 4.7 Consegna

Procedura per produrre una copia per un destinatario:

1. scegliere cosa: tutto il reperto, alcune cartelle (acquisizione logica), alcuni file con la loro prova di
   appartenenza;
2. scegliere a chi: chiave pubblica del destinatario (cifratura per destinatario, anche post-quantum) o
   password comunicata a parte;
3. scegliere il formato: XIZ (consigliato), raw + hash, E01;
4. generare: copia, ricevuta firmata, evento di custodia sull'originale.

### 4.8 Riga di comando

Stesse funzioni, per laboratori e script (sintassi provvisoria, vedi FORENSE_3.1 §4.6):

```
xipper-forensic devices                     elenco con modello, seriale, stato di montaggio
xipper-forensic case new "2026-117" --examiner "Mario Rossi"
xipper-forensic acquire --case 2026-117.xfcase --evidence R02 --device disk4 --md5 --sign keychain:…
xipper-forensic verify R02.xiz [--expect-sha256 HASH] [--report r.pdf --json r.json]
xipper-forensic custody R02.xiz --from … --to … --note "sigillo 4471"
xipper-forensic export R02.xiz --raw - | sha256sum
xipper-forensic export R02.xiz --e01 R02.E01
```

---

## 5. Funzioni e priorità

**[Proposta]** Tre livelli. «1.0» è il minimo che un consulente userebbe davvero in un incarico.

| Funzione | 1.0 | 1.1 | Dopo |
|---|:-:|:-:|:-:|
| Caso, reperti, log del caso firmato a catena | ● | | |
| Acquisizione logica (cartelle, con xattr e date; elenco esclusi e illeggibili) | ● | | |
| Mac via «Condividi disco» con montaggio SMB forzato in sola lettura (`mount_smbfs -o ro`) [R51] | ● | | |
| Assistente Mac e registrazione dei cambiamenti di stato (Secure Boot, SIP) | ● | | |
| Controlli prima dell'avvio (✔/⚠/⛔), esito a tre stati, profili di laboratorio | ● | | |
| Più destinazioni in parallelo (master + lavoro) | | ● | |
| Snapshot APFS locali | | ● | |
| Acquisizione fisica e di volume da `/dev/rdiskN`, blocco del montaggio | ● | | |
| Settori illeggibili: riletture, mappa, zeri | ● | | |
| Hash SHA-256 + MD5/SHA-1 facoltativi, hash dei frame (Merkle) | ● | | |
| Verifica automatica dopo l'acquisizione, verificatore standalone | ● | | |
| Firma Ed25519 dal Portachiavi, marca RFC 3161 | ● | | |
| Report JSON + PDF stampabile | ● | | |
| Custodia (passaggi di mano firmati) | ● | | |
| Export raw | ● | | |
| Firma con certificato X.509 (Secure Enclave, smart card PIV) | | ● | |
| TSA con autenticazione, verifica stato qualificato (EU Trusted List) | | ● | |
| Export E01, import E01 | | ● | |
| Consegna per destinatario con prove di file | | ● | |
| Montaggio in sola lettura con verifica di ogni lettura | | ● | |
| Seconda lettura della sorgente (stabilità SSD) | | ● | |
| Più acquisizioni in parallelo | | ● | |
| Anteprima/triage prima dell'acquisizione (elenco file di un volume) | | | ● |
| Firma qualificata italiana (CNS, firma remota) | | | ● |
| Plugin The Sleuth Kit/Autopsy su libxiz | | | ● |
| `xizcat`/`xiz-verify` per Linux e Windows nei rilasci | | ● | |

Fuori ambito, per scelta: analisi degli artefatti, carving, ricerca per parole chiave, RAM, mobile, cloud,
cancellazione sicura, recupero password.

---

## 6. Decisioni

**[Fatto]** Prese dal proprietario il 10/11/2026.

| # | Domanda | Decisione |
|---|---|---|
| D1 | Nome della CLI | `xipper-forensic`, con alias `xfor` |
| D2 | Dove vive il codice | stesso repository: target `ForensicKit`, cartella `App/XipperForensic/`; formato e test evolvono insieme |
| D3 | Privilegi | helper root minimo con `SMAppService` (apre il disco in sola lettura, blocca il montaggio); se non si registra con la firma self-signed, l'app rimanda alla CLI con `sudo` |
| D4 | Lingue | italiano e inglese alla 1.0, lessico giuridico curato a mano; altre lingue dopo |
| D5 | Licenza e prezzo | tutto MIT e gratuito, come Xipper: app, CLI, verificatore |
| D6 | Profilo forense nel formato | **bit richiesto `forensic`** in una nuova versione XIZ (1.10): un lettore vecchio rifiuta il file con un errore chiaro invece di ignorare mappa dei settori e hash dei frame |
| D7 | Prima release | **0.9 anteprima**: caso e log, acquisizione logica, «Condividi disco», acquisizione da file immagine, verifica, custodia, report. Dischi fisici con l'helper nella **1.0** |
| D8 | Acquisizione live del Mac stesso | dopo la 1.0; prima «Condividi disco» da un secondo Mac |

Conseguenze:
- la tabella del §5 va letta con una colonna «0.9» = righe 1.0 senza la lettura da `/dev/rdiskN` e senza l'helper;
- la fase P4 (dispositivi) separa 0.9 e 1.0; la prova di `SMAppService` con firma self-signed è fatta (§3.1): l'helper funziona, il ripiego CLI resta solo come alternativa;
- FORENSE_3.1 §5.6, prima domanda: chiusa da D6.

## 7. Piano

**Note sulla P1 (10/11/2026).** Scelte di formato rispetto a FORENSE_3.1 §4.1:
- l'immagine è una voce *file* con il campo non critico `0x000C image`, non un tipo nuovo: estrazione, montaggio e anteprima di Xipper funzionano senza modifiche; i blocchi tutti a zero puntano a un solo «frame di zeri» invece di un extent speciale;
- i record forensi stanno in un **blocco forense** per segmento, coperto dalla firma tramite la directory versione 3;
- i **segmenti di custodia** ripetono cataloghi e foglie del segmento precedente: si aggiungono e si firmano senza la chiave del contenuto;
- libxiz verifica SHA-256 ma non MD5 e SHA-1 (la BearSSL inclusa non li ha) né le marche temporali;
- prova su NIST CFReDS (10/11/2026): 4 immagini, hash di NIST riprodotti esattamente; CFReDS non pubblica SHA-256;
- libxiz verifica anche le acquisizioni logiche contro l'inventario firmato (parser JSON piatto in C, con test su input ostili); gli orari della sorgente sono in millisecondi;
- un troncamento agli ultimi segmenti resta valido per costruzione: lo chiude solo l'hash del verbale (`--expect-sha256`) o il numero di passaggi di custodia annotato fuori.


**Note sulla P3 (10/11/2026).**
- App `Xipper Forensic.app` (`app.xipper.forensic`): target SwiftPM `XipperForensic` in `App/XipperForensic/Sources`, impacchettata e firmata «Xipper Self-Signed» da `scripts/build-forensic-app.sh` (CLI inclusa in `Contents/Helpers`). Non tocca il progetto Xcode di Xipper.
- Finestre: benvenuto (nuovo caso, apri caso, verifica archivio, casi recenti), caso (riepilogo modificabile, registro con note, reperti), reperto (stato a tappe, hash con copia, custodia, verifica di nuovo, report PDF, cronologia), verifica di un `.xiz` qualunque (hash dal verbale, password facoltativa, esportazione PDF/JSON), impostazioni (operatore, chiave di firma nel Portachiavi, lingua dei report, TSA o modalità offline).
- Procedura guidata in sei passi: reperto · sorgente (file e cartelle, file immagine, Mac via «Condividi disco» montato con NetFS `MNT_RDONLY|MNT_NOEXEC|MNT_NOSUID|MNT_NODEV`, rifiutato se non risulta in sola lettura) · opzioni · controlli ✔/⚠/⛔ con conferma dell'operatore scrivendo il nome (controlli e conferma entrano nel registro) · avanzamento con pausa e interruzione motivata · esito a tre stati. Durante l'acquisizione il Mac non va in stop.
- Report PDF A4 (`ForensicPDF`, CoreText, senza AppKit) generato dallo stesso JSON, in italiano o inglese; ogni pagina porta caso, archivio, SHA-256 e «pagina n di N». Scritto e firmato (`.pdf.sig`) a ogni acquisizione e custodia; il suo hash è nel registro, quindi `case verify` si accorge se viene sostituito. CLI: `report --pdf FILE --lang it|en`, `--lang` anche per `acquire --in` e `custody --in`.
- Stringhe: 226, italiano completo (`scripts/forensic-strings.py` lo controlla). I dettagli dei controlli che arrivano da XipperKit restano in inglese.
- Le build debug hanno `--snapshot DIR CASO` che disegna ogni schermata in PNG: così le schermate sono state controllate senza clic.
- Prova a mano del proprietario (10/11/2026): emerso e corretto un difetto, la chiave di firma appena creata non sbloccava «Nuovo caso» finché l'app non veniva riaperta.
- Non provato: «Condividi disco» (serve un secondo Mac in recoveryOS), rimandato alla P3b.

Si appoggia alle fasi F0–F8 di FORENSE_3.1 §6, riordinate per il prodotto.

| Fase | Contenuto | Fatto quando |
|---|---|---|
| P0 ✅ | Questo studio e decisioni D1–D8 | decise il 10/11/2026 (§6) |
| P1 ✅ | Spec del profilo forense (XIZ 1.10, [XIZ_SPEC.md §20](XIZ_SPEC.md)) + vettori di prova; libxiz li legge | fatta il 10/11/2026: `XizForensic.swift`, CLI `xipper-forensic` (acquire da file immagine, custody, verify, info), 7 test Swift; libxiz legge 1.10 e verifica con `xiz forensic`; vettori in `libxiz/tests/fixtures/forensic*` verificati da entrambi |
| P2 ✅ | ForensicKit: caso, log, acquisizione logica e da file immagine, verifica, report JSON | fatta il 10/11/2026: cartella `.xfcase` con registro JSON Lines firmato a catena (Ed25519, `prev` = SHA-256 della riga prima); acquisizione logica con `forensic/inventory.jsonl` (ogni elemento trovato, anche illeggibile o speciale, con metadati e SHA-256) il cui hash è nel record firmato; report JSON firmato a parte (`.sig`); CLI `case new/show/verify/note`, `acquire --logical`, `acquire --in`, `custody --in`, `report`; 10 test Swift; `scripts/forensic-hashes.sh`: SHA-256, SHA-1 e MD5 uguali a `shasum`/`md5` da 0 byte a 13 MiB; `scripts/cfreds-check.sh`: MD5 e SHA-1 uguali a quelli pubblicati da NIST CFReDS su 4 immagini (Rhino Hunt 260 MB, Basic Mac 103 MB, Data Leakage RM#3 108 MB e RM#2 4 GB), immagine riletta da libxiz identica. Il PC del Data Leakage (21 GB) non è stato provato per lo spazio su disco |
| P3 ✅ | App: caso, reperti, procedura guidata, avanzamento, verifica, custodia, report PDF | fatta il 10/11/2026 (note sotto), prova a mano del proprietario; «Condividi disco» resta da provare nella P3b |
| P3b | Rilascio 0.9 anteprima (D7): DMG proprio, release `forensic-v0.9.0` | prova a mano completa: Mac via «Condividi disco», cartelle, immagine da file |
| P4 | Dispositivi: helper, Disk Arbitration, IOKit, settori illeggibili | FORENSE F3 |
| P5 | Firma con certificato, TSA autenticata, export/import E01, consegna | FORENSE F4, F6 |
| P6 | Rilascio 1.0: DMG proprio, `xizcat` multipiattaforma, documento di validazione stile NIST CFTT | report di validazione pubblicato |

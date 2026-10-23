# Studio FSKit: montare gli archivi come volumi (v2, primo punto)

Studio e spike del 21/10/2026, su macOS 27.2 con Xcode 27 (SDK MacOSX27.0). Obiettivo: aprire un archivio come volume in sola lettura nel Finder, senza estrarlo ([ROADMAP](ROADMAP.md), v2 §1).

## In breve

> **Aggiornamento del 21/10/2026:** niente account Apple. Lo spike dell'**opzione C (WebDAV locale)** funziona: vedi la sezione "Spike dell'opzione C". È la strada per la v2; FSKit resta il sostituto naturale se un giorno ci sarà un account sviluppatore.

- **Tecnicamente funziona.** Dal 26.0 FSKit ha `FSPathURLResource`, che monta un *file* (il nostro archivio) invece di un disco. Il modulo dello spike compila al primo colpo, il sistema lo registra accanto ai moduli Apple (msdos, exfat, ftp) e, una volta attivato in Impostazioni, `mount -F -t xipperfs archivio.zip punto` lo invoca.
- **C'è un blocco: l'entitlement `com.apple.developer.fskit.fsmodule` è riservato.** Con la firma self-signed il sistema rifiuta di avviare l'estensione:

  ```text
  taskgated-helper: Disallowing app.xipper.spike.fs because no eligible provisioning profiles found
  amfid: Restricted entitlements not validated, bailing out. Error … Code=-413 "No matching profile found"
  ```

  Senza l'entitlement il processo parte, ma FSKit chiude la connessione (`Connection error getting endpoint`, Cocoa 4099). Non c'è una terza via.
- **Conseguenza:** FSKit richiede un provisioning profile Apple, quindi un account sviluppatore, e questo è in conflitto con la decisione "solo DMG self-signed, niente Developer ID". Da verificare con Apple: se l'entitlement è disponibile anche con un profilo **Developer ID** (distribuzione fuori dallo store). La documentazione cita solo la compatibilità con il Mac App Store.

## Cosa offre FSKit (dagli header dell'SDK)

| Versione | macOS | Novità rilevanti per Xipper |
|---|---|---|
| V1 | 15.4 | `FSUnaryFileSystem` (una risorsa → un volume), `FSVolume.Operations`, `ReadWriteOperations`, `OpenCloseOperations`, `XattrOperations`; solo risorse a blocchi |
| V2 | 26.0 | **`FSPathURLResource`** (un file o una cartella come risorsa, anche security-scoped), `FSGenericURLResource`, `enableOpenUnlinkEmulation` |
| V2.4 | 26.4 | `requestedMountOptions` |
| V3 | 27.0 | protocolli `FSVolume.Handler` (sostituiscono gli `Operations` e restituiscono attributi e spazio libero), `FSClient.mountSingleVolume(resource:bundleID:options:)` per montare da un'app (entitlement `com.apple.developer.fskit.mount`), `openFileSystemExtensionsSettings()` |

**Note pratiche**
- Il modulo è un'estensione ExtensionKit (`UnaryFileSystemExtension`, `CFBundlePackageType` `XPC!`), dentro `Xipper.app/Contents/Extensions/`, con sandbox attiva.
- Va dichiarata nell'Info.plist (`EXAppExtensionAttributes`) con `FSShortName`, `FSPersonalities` e `FSSupportsPathURLs = true`.
- L'utente deve attivarla una volta in **Impostazioni di Sistema › Generali › Elementi login ed estensioni › Estensioni del file system**. Prima di questo, il mount risponde "Module … is disabled!".
- Per supportare macOS 26 bisogna usare i protocolli V1/V2 (`FSVolume.Operations`), deprecati in 27 ma disponibili. In alternativa si implementano entrambi, con `@available`.
- **Montaggio:**
  - dalla riga di comando: `mount -F -t xipperfs <file> <cartella>`;
  - dall'app, su macOS 27: `FSClient.mountSingleVolume`, che monta in `/Volumes/` (serve anche l'entitlement `fskit.mount`, quasi certamente riservato anch'esso).
- **Accesso al file:** dalla sandbox l'estensione riceve il percorso come `FSPathURLResource`. `FSRequiresSecurityScopedPathURLResources = false` permette percorsi passati da `mount`. Lo spike legge l'archivio nell'`init` del volume: è da verificare, perché lo spike non è arrivato a quel punto.

## Lo spike

Si trova in [`spike/fskit/`](../spike/fskit/): `build.sh`, il modulo `XipperFS.swift` e un host vuoto.

- **Cosa fa:** è un `FSUnaryFileSystem` completo in sola lettura. Fa probe e load del percorso, gestisce attivazione, montaggio, lookup, attributi, enumerazione della cartella, apertura e lettura. Espone un solo `info.txt` con il percorso, la dimensione e i primi 16 byte dell'archivio.
- **Esito:**

| Passo | Esito |
|---|---|
| Compilazione con `swiftc` (senza progetto Xcode) | ✅ |
| Registrazione (`pluginkit -m -p com.apple.fskit.fsmodule`) | ✅ visibile accanto a msdos, exfat e ftp |
| Attivazione in Impostazioni di Sistema | ✅ (fatta dall'utente) |
| `mount -F -t xipperfs drag.zip mnt` | ❌ AMFI −413: entitlement riservato senza profilo |
| Stesso, firmato senza entitlement | ❌ l'estensione parte ma FSKit rifiuta la connessione |

Lo spike è stato poi rimosso dalla registrazione (`lsregister -u`, `pluginkit -r`).

## Opzioni

| | Opzione | Pro | Contro |
|---|---|---|---|
| **A** | **Apple Developer Program** (99 €/anno), con profilo **Developer ID** che includa FSKit | integrazione nativa, la migliore esperienza; sblocca anche la notarizzazione (niente più "Apri comunque") | costo annuale; rivede la decisione del 21/10; **da verificare** che FSKit sia concesso ai profili Developer ID (altrimenti solo Mac App Store, che escludiamo) |
| **B** | Account gratuito (Personal Team) | gratis, utile per sviluppare e provare lo spike | il profilo vale solo per i Mac registrati dello sviluppatore e scade: **non distribuibile** |
| **C** | **Server di rete locale dentro Xipper** (NFSv4 o WebDAV su `localhost`) montato con il client di macOS, come fa FUSE-T | nessun entitlement, nessuna estensione da attivare, funziona con la firma self-signed | prestazioni e integrazione inferiori (volume "di rete", latenza, xattr limitati con WebDAV); serve un server NFS/WebDAV in sola lettura scritto da noi, da valutare con uno spike; il montaggio come utente va verificato (`mount_nfs` vuole root, NetFS/Finder no) |
| **D** | macFUSE / FUSE-T installati dall'utente | API FUSE mature | dipendenza esterna da installare: viola il principio "autocontenuto" |

**Raccomandazione.** Se il montaggio deve essere *la* funzione della v2, l'opzione A è l'unica che dà l'esperienza nativa, e risolve anche "Apri comunque". Va fatta una sola verifica preliminare: chiedere ad Apple (Developer Technical Support o i forum) se `fskit.fsmodule` è disponibile per i profili Developer ID. Nel frattempo B serve a proseguire lo sviluppo senza costi. Se A non è percorribile, C è il ripiego senza Apple, da validare con uno spike NFS/WebDAV in sola lettura.

## Spike dell'opzione C: WebDAV locale (21/10/2026)

**Decisione dell'utente:** niente account Apple. Si prova il ripiego.

**Perché WebDAV e non NFS:**
- `mount_webdav` è nel sistema e monta **come utente normale**;
- un server WebDAV in sola lettura (classe 1: OPTIONS, PROPFIND, GET/HEAD) sono poche centinaia di righe;
- un server NFSv4 richiede RPC/XDR e le operazioni COMPOUND: parecchie migliaia di righe.

**Lo spike:** [`spike/webdav/`](../spike/webdav/), `xipdav <archivio> [porta]`.
- Server HTTP/1.1 con Network.framework, solo su `127.0.0.1`, con un token casuale nel percorso.
- Albero costruito da `Xipper.list`, contenuto letto con `Xipper.readEntry` e messo in una cache in memoria.
- Stesse regole dell'estrazione sicura: niente `..` né `.`.
- Tutto ciò che scrive (PUT, MKCOL, LOCK, DELETE, MOVE…) riceve 403.
- **Si monta con:** `mount_webdav -S -o rdonly http://127.0.0.1:<porta>/<token>/ <cartella>`.

**Risultati** (archivio ZIP da 300 MB: 50 sorgenti più un file da 300 MB):

| Prova | Esito |
|---|---|
| Montaggio come utente, senza root né entitlement, con firma qualsiasi | ✅ 0,17 s, volume `webdav, read-only, nodev, noexec, nosuid` |
| `find` sull'albero | ✅ 0,08 s |
| `diff -r` dei sorgenti e `cmp` del file da 300 MB con gli originali | ✅ identici |
| Lettura completa del file da 300 MB | ✅ 0,66 s (0,12 s lato server) |
| 200 letture casuali da 4 KB | ✅ corrette, circa 0 ms (dalla cache locale del client) |
| Scrittura (`touch`) | ✅ rifiutata: "Read-only file system" |
| Server terminato con il volume montato | ✅ con `-S` il volume si smonta da solo, senza dialoghi né blocchi |
| Memoria del server | ⚠️ 1,7 GB: cache dell'intera voce più copie dei dati |

**Comportamento del client WebDAV di macOS** (dal log del server):
- alla prima apertura scarica **l'intero file** con un GET senza Range e poi legge dalla cache su disco;
- cerca i file `._*` e `.DS_Store` (rispondiamo 404);
- 55 PROPFIND e 51 GET per il giro di prova.

**Limiti dell'opzione C:**
- **File molto grandi:** aprire una voce da 20 GB significa trasferirla tutta nella cache del client prima di leggerne il primo byte, occupando altrettanto disco. Per i file comuni non si nota; per BAM e FASTQ genomici sì.
- Permessi e proprietario non sono quelli dell'archivio: tutto appare `rwx------` dell'utente. Il volume è `noexec`. Niente xattr né tag del Finder.
- È un volume "di rete": Spotlight non lo indicizza, e il Finder lo mostra come server.
- **Sicurezza:**
  - la porta è solo su loopback, ma l'URL (con il token) compare nell'output di `mount`, visibile a tutti gli utenti locali;
  - la versione vera deve chiedere credenziali HTTP casuali per ogni montaggio, passate con l'API NetFS (`NetFSMountURLSync` accetta utente e password) invece della riga di comando.

**Valutazione.** WebDAV è una strada **percorribile per un MVP senza Apple**: si sfoglia e si apre dal Finder, è in sola lettura e si smonta da sé. Va bene per archivi con file di dimensioni normali. Per i file enormi la soluzione giusta resta FSKit, oppure un server NFSv4 locale (letture a blocchi, xattr), molto più costoso da scrivere.

**Cosa serve per farne una funzione:**
1. GET in streaming dalla decodifica, senza tenere la voce in memoria: serve un'API pubblica di XipperKit che legga una voce verso un sink, e una cache a blocchi per i formati ad accesso casuale (XIZ, ZIP stored, tar non compresso).
2. Autenticazione Digest o Basic con credenziali casuali per montaggio; montaggio dall'app con NetFS (`-S` equivalente), smontaggio con «Espelli».
3. Il server vive nell'app (o in un helper di login) finché il volume è montato. Azione «Monta» nel browser e nel menu del Finder, `xipper mount` nella CLI.
4. Password degli archivi cifrati dal portachiavi; voci cifrate senza password: 403.
5. Test: montaggio automatico, confronto byte per byte, server terminato, voci enormi, nomi Unicode e caratteri speciali negli URL.

## Implementazione (21/10/2026): montaggio in lettura e scrittura

Su richiesta dell'utente il montaggio è **in lettura e scrittura**. Il codice è in `Sources/XipperKit/Mount/`.

- **`Xipper.streamEntry(_:path:from:)`:** legge una voce a blocchi da un offset, senza estrarre l'archivio.
  - XIZ salta direttamente ai frame che servono; gli altri formati decodificano e scartano la parte iniziale.
  - Su questa funzione ora si basa `readEntry`. Corretto un difetto che c'era già: l'anteprima delle voci Apple Archive passava dal lettore tar/cpio.
- **`MountedArchive`:** l'albero dell'archivio con uno strato copy-on-write su disco.
  - I file scritti finiscono nell'overlay e coprono le voci dell'archivio.
  - Le cancellazioni sono whiteout, che nascondono anche il contenuto delle cartelle.
  - Copia e spostamento passano dall'overlay.
  - `save()` estrae, applica le modifiche e ricrea l'archivio nel suo formato e con la sua password; l'originale viene sostituito in modo atomico solo a fine lavoro.
  - Restano esclusi i file `._*` e `.DS_Store` del Finder.
  - I formati a file singolo (gz, xz, …) restano in sola lettura.
- **`DAVServer`:** server WebDAV su 127.0.0.1, un thread per connessione con socket bloccanti, quindi con contropressione.
  - Classe 2 (LOCK/UNLOCK, PUT, MKCOL, DELETE, COPY, MOVE, PROPPATCH) quando l'archivio è scrivibile, classe 1 altrimenti.
  - Credenziali Basic casuali per ogni montaggio, e un prefisso casuale nel percorso.
  - GET in streaming con Range, PUT in streaming su disco (anche chunked e con `Expect: 100-continue`).
  - Percorsi normalizzati come nell'estrazione sicura.
- **`ArchiveMount`:** avvia il server e monta con `NetFSMountURLSync` (`kNetFSAllowLoopbackKey`, nessuna interfaccia, `nosuid,nodev`, `rdonly` se in sola lettura) su `/Volumes/<nome>`. Poi segue lo smontaggio e salva o scarta.
- **Interfacce:**
  - **CLI:** `xipper mount [--read-only] [--discard] [--at DIR]`.
  - **App:** pulsante «Monta»/«Espelli» nel browser, voce «Monta come volume» nel menu Xipper del Finder.
  - All'espulsione, se ci sono modifiche, l'app chiede «Salva» / «Non salvare». All'uscita dall'app i volumi vengono espulsi e salvati, dopo una conferma.
- **Test:** `MountTests` coprono:
  - lo streaming da offset su 7 formati;
  - le regole dell'overlay;
  - il salvataggio su ZIP/7z con password, tar.zst, XIZ e Apple Archive;
  - il server (401, Range, traversal, PUT chunked con 100-continue, MKCOL/MOVE/COPY/LOCK/DELETE/PROPPATCH);
  - due **montaggi reali** con NetFS (lettura e scrittura, e sola lettura), che si saltano con `XIPPER_SKIP_MOUNT=1`.
- **Prove a mano nell'app:**
  - monta, scrivi un file, espelli, «Salva»: l'archivio contiene il file e il browser si ricarica;
  - espulsione dal Finder senza modifiche: nessuna domanda.

**Limiti:**
- Il client WebDAV di macOS scarica l'intero file alla prima apertura.
- Permessi, xattr e tag del Finder dei file modificati non vengono conservati, mentre le voci non toccate li conservano.
- Il salvataggio ricrea l'intero archivio, quindi costa quanto una ricompressione.
- Il server vive nel processo dell'app o della CLI: se il processo termina, il volume viene smontato e le modifiche non salvate si perdono.

## Piano una volta sbloccato

1. **Architettura.**
   - `XipperFS.appex` nell'app, che usa XipperKit come framework condiviso (serve trasformare XipperKit in un framework incluso, oggi è statico).
   - Albero delle voci costruito dal catalogo dell'archivio (ZIP: directory centrale; XIZ: catalogo; tar: scansione iniziale con indice in memoria).
   - Cache dei blocchi decompressi con un tetto di memoria.
2. **MVP:**
   - ZIP, incluso AES con la password dal portachiavi tramite l'app;
   - tar non compresso;
   - XIZ e tar.zst con frame indipendenti.
   - Azioni «Monta» e «Espelli» nel browser e nel menu del Finder, `xipper mount` nella CLI.
3. **Sicurezza:** gli stessi controlli dell'estrazione sicura (nomi, symlink solo interni, limiti contro le zip-bomb applicati alla cache); fuzzing del percorso di montaggio.
4. **Test:**
   - montaggio e smontaggio automatici in CI locale (con modulo attivato);
   - confronto byte per byte con l'estrazione;
   - accesso concorrente;
   - Quick Look e Spotlight sul volume.
5. **Poi:** 7z (cache per cartella solida), tar.gz/xz con un indice costruito al primo montaggio, BGZF con `.gzi`.

## Fonti

- Header e template dell'SDK macOS 27.0 (FSKit.framework, "File System Extension.xctemplate").
- Log di sistema dello spike (`taskgated-helper`, `amfid`, `fskit_agent`).
- [Documentazione FSKit](https://developer.apple.com/documentation/fskit); forum Apple sui [moduli FSKit](https://developer.apple.com/forums/tags/fskit) e sull'[attivazione dei moduli](https://developer.apple.com/forums/thread/808594).
- [FUSE-T](https://github.com/macos-fuse-t/fuse-t): server NFSv4 locale al posto della kext.

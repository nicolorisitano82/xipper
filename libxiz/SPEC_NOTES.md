# Note sulla specifica XIZ 1.4 (da un'implementazione indipendente)

libxiz implementa `docs/XIZ_SPEC.md`, non il codice Swift. Queste note raccolgono i punti in cui
la spec è ambigua, incompleta o non coincide con l'implementazione di riferimento
(`Sources/XipperKit/Xiz/`), e cosa fa libxiz in ciascun caso. Riferimenti: §n della spec.
Nessuna modifica è stata fatta alla spec né al codice Swift.

## Lacune: cose che il riferimento scrive e la spec non descrive

1. **Campo `0x000B` "sealed proof" (§13.6, §13.7).** Per le voci cancellabili Xipper non scrive
   il campo `0x0009 proof` ma un campo `0x000B` di 76 byte: `nonce[12] ‖ AES-256-GCM(K, salt ‖
   content_sha256) ‖ tag[16]`, con `K = HKDF-SHA-256(entry key, salt assente, info "xiz/1.3/proof")`
   e dati associati `"XIZ13proof"` (`XizProof.swift`, `XizLeaf.sealProof`). Così la foglia Merkle
   di una voce cancellata non è più ricostruibile. Il campo non è critico, quindi un lettore che
   segue solo la spec lo salta senza errori, ma non può né verificare l'albero per quelle voci né
   produrne le prove. libxiz lo legge come il riferimento. **Proposta:** aggiungere a §13.7 la
   riga della tabella dei tag e la derivazione della chiave.
2. **Bit 1 dei flag di frame (§4.1 contro §13.7).** §4.1 dice "flags: bit 0 = dictionary frame;
   other bits zero"; §13.7 definisce il bit 1 (`entry key`). La tabella di §4.1 andrebbe aggiornata.
3. **Byte 24–25 dell'header di frame (§4.1 contro §13.2).** §4.1 li dichiara riservati e zero;
   §13.2 vi scrive il gruppo. Anche qui conviene un rimando in §4.1. libxiz ricostruisce l'header
   con il gruppo e lo confronta byte per byte.
4. **`version_minor` del footer (§7, §11).** §11 dice che il footer di un segmento aggiunto ha
   `version_minor = 1`. Xipper scrive 1 negli archivi 1.0, ma 3 negli archivi 1.3 con segmenti
   (fixture `signed.xiz`: footer 3 e 3) e 0 nel footer di un archivio 1.4 (`lzma2.xiz`:
   superblock 4, footer 0). Il campo è coperto dai dati associati del catalogo cifrato (§6.5),
   quindi conta per l'autenticazione ma non ha una semantica definita. libxiz non lo valida
   (controlla solo `version_major`). **Proposta:** dire che il footer porta il minor del
   superblock, oppure che è informativo.
5. **Etichetta nel messaggio firmato (§13.5).** La formula termina con `label`, senza dire se
   include il byte di lunghezza. Il riferimento usa lo stesso formato del record: `u8 length ‖
   UTF-8`. libxiz fa lo stesso; con l'altra lettura nessuna firma verificherebbe.
6. **Chiave di slot nell'elenco di §6.1.** `xiz/1.3/slots` compare solo in §13.7; si può
   aggiungere alla tabella delle derivazioni.

## Ambiguità

7. **Ultimo blocco STREAM (§6.5).** "the last one may be shorter or empty": non è chiaro se,
   quando il catalogo compresso è un multiplo esatto di 65.536 byte, si aggiunga un blocco vuoto
   finale. Il riferimento non lo aggiunge (l'ultimo blocco pieno porta `last = 1`); il blocco
   vuoto esiste solo per un catalogo vuoto. libxiz accetta entrambe le forme in lettura e scrive
   come il riferimento.
8. **"Consistent codec sizes" (§8 passo 5).** Non è definito quanto un frame compresso possa
   superare i suoi dati. libxiz usa lo stesso limite del riferimento: `csize ≤ 64 MiB + 4096`,
   `csize = usize (+16)` per `store`.
9. **Dizionari con la directory (§12, §13.2).** La spec vieta i dizionari solo "with more than
   one group"; il riferimento li rifiuta in qualunque archivio con directory (`f.dictionary == 0`).
   libxiz segue la spec: li accetta con un solo gruppo e la feature `dictionaries`.
10. **Totali del footer con gruppi nascosti o voci cancellate (§13.1, §13.7).** I totali coprono
    tutti i gruppi; quando un lettore non ha alcune chiavi, o uno slot è stato azzerato ma il
    segmento che toglie la voce non è ancora stato scritto, non può confrontarli esattamente. Il
    riferimento richiede `≤`; libxiz fa lo stesso e richiede l'uguaglianza solo quando vede tutto.
11. **Stanza di tipo 1 con `directory`, tipi 2–5 senza (§6.2, §13.3).** "Type 1 is not used
    together with directory" non dice cosa fa il lettore se la trova. Il riferimento ignora il
    tipo 1 negli archivi con directory e i tipi 2–5 in quelli senza; libxiz idem (stanza saltata
    come sconosciuta).
12. **`catalog_usize = catalog_csize` per la directory (§13.1).** Il riferimento non lo controlla;
    libxiz sì (è un "must" implicito della frase).
13. **Segmenti dei cataloghi di gruppo (§13.1).** "the current one for catalogs written in this
    segment" lascia intendere cataloghi più vecchi; §13.4 impone però di riscriverli tutti. libxiz,
    come il riferimento, richiede che ogni catalogo della directory corrente sia del segmento
    corrente.
14. **Inizio della regione di un segmento precedente (§11, §13.1).** La tabella di slot di un
    segmento più vecchio non porta il numero di quel segmento in modo diretto quando si risale la
    catena; il riferimento la riconosce perché "finisce dove comincia il primo catalogo". libxiz
    usa la stessa regola. Inoltre libxiz controlla che ogni regione dichiarata sia effettivamente
    "consumata" tra i frame: un frame che la scavalca è rifiutato.
15. **Foglie oltre le voci (§13.6).** Il riferimento richiede `leaf_count ≤ entry_count` e foglie
    ordinate; la spec dice solo che sono ordinate. libxiz verifica entrambe.

## Differenze di rigore (il riferimento è più permissivo della spec)

16. **Un solo frame zstd (§1, §4.2, §5).** Il riferimento decodifica con `ZSTD_decompress`, che
    accetta più frame concatenati e frame "skippable". libxiz richiede esattamente un frame
    (`ZSTD_findFrameCompressedSize == csize`), come dice la spec; gli archivi di Xipper rispettano
    la regola.
17. **Byte dopo l'ultima stanza (§6.2).** Il lettore 1.0 del riferimento non controlla che il
    keys block finisca con l'ultima stanza; libxiz lo richiede (come fa il lettore 1.3 del
    riferimento).
18. **Byte riservati del superblock (§3).** libxiz rifiuta un superblock con byte 36–59 non nulli.
19. **Punti X25519 di ordine basso (§13.3).** La spec non ne parla; libxiz scarta un segreto
    condiviso nullo.

## Cose che libxiz non fa (ancora)

- Verifica della marca temporale RFC 3161 (§13.5): libxiz riporta solo che il token c'è. Serve
  un verificatore CMS/X.509, fuori dallo scopo di una libreria piccola.
- Lettura degli archivi beta 0.1 (§9): implementata dietro `XIZ_OPEN_ALLOW_BETA`, ma senza
  fixture per provarla.
- Recovery data (`optional_features` bit 0): ignorata, come consente la spec.

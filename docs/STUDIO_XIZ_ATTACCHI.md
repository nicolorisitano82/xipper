# XIZ contro forza bruta e altri attacchi

*Studio del 16/11/2026, su XIZ 1.13 (Xipper 3.4). Fonti: [XIZ_SPEC.md](XIZ_SPEC.md) §6, §11, §13, §17; `Sources/XipperKit/Xiz/XizFormat.swift`; `App/Xipper/Views/PasswordSheet.swift`. I numeri sulle prestazioni degli attaccanti sono stime ricavate dalla banda di memoria, non misure.*

## 1. In breve

- Chi ha il file attacca **offline**: niente limiti di tentativi né ritardi lato app. Contano solo due cose: quanto costa un tentativo e quanti tentativi servono.
- Oggi un tentativo costa già molto: Argon2id con 256 MiB, 3 passaggi e parallelismo 4, circa 0,2 s su un Mac. Raddoppiare o quintuplicare questo costo sposta poco.
- **La leva vera è l'entropia del segreto.** Una password umana tipica (30–40 bit effettivi) cade in giorni o settimane con un migliaio di GPU. Una passphrase da 6 parole (77 bit) o una chiave pubblica non cadono.
- **Proposte**, in ordine di valore:
  1. Misurare davvero la robustezza della password, generare passphrase nell'app e rifiutare quelle deboli, salvo conferma esplicita.
  2. Un secondo fattore per la password: un file chiave, il Portachiavi o il Secure Enclave.
  3. Profili KDF più pesanti, scelti con una calibrazione sul Mac.
  4. *Key commitment* nel formato, contro gli archivi costruiti per aprirsi con più chiavi.
  5. Avvisi su parametri deboli scritti da altri programmi e sul ritorno a una versione precedente.

## 2. Cosa protegge XIZ oggi

| Livello | Meccanismo | Effetto contro gli attacchi |
|---|---|---|
| Password → chiave | Argon2id (RFC 9106), 256 MiB, t=3, p=4, salt casuale di 32 byte | Costo per tentativo alto e legato alla memoria; il salt impedisce le tabelle precalcolate |
| Verifica | Nessun verificatore separato: la password si prova solo togliendo l'involucro AES-GCM della chiave del file | Non esiste una scorciatoia più economica di un Argon2id completo |
| Parametri | Parametri KDF e superblocco nei dati associati dell'involucro | Un attaccante non può abbassare i parametri di un archivio esistente |
| Lettori | Limiti 19 MiB–2 GiB, 1–10 passaggi, 1–16 thread | Nessun DoS con parametri enormi |
| Contenuto | AES-256-GCM per frame (nonce = indice), catalogo STREAM, AEAD su posizione e contatori | Manomissioni, troncamenti, riordini e scambi di frame tra archivi vengono rilevati |
| Metadati | Nomi, dimensioni e digest (HMAC con chiave) cifrati; chunking con parametri derivati dalla chiave | Niente impronte del testo in chiaro |
| Alternative alla password | X25519, X-Wing (ML-KEM-768 + X25519), soglie k-di-n, chiavi nel Portachiavi con Touch ID | Contro una chiave da 256 bit la forza bruta è impossibile |
| Integrità e origine | Segmenti firmati in catena (Ed25519, ML-DSA-65 ibrido, Secure Enclave, certificati) | Chi non ha la chiave non può aggiungere né cambiare versioni |

## 3. Modello di minaccia

1. **Forza bruta offline sulla password** (stanze 1 e 2): l'attaccante ha il file, una GPU farm, dizionari e regole (hashcat, john). È l'attacco principale.
2. **Archivio costruito ad arte** da un mittente malevolo: un archivio che mostra contenuti diversi a destinatari diversi, o che si apre con più password scelte (*partitioning oracle*).
3. **Ritorno a una versione precedente:** gli archivi con segmenti si possono troncare a un footer precedente, e restano validi.
4. **Archivi scritti da altri programmi** (libxiz, `xiz`, terze parti) con parametri KDF al minimo consentito.
5. **Fughe dai metadati visibili:** numero e dimensioni dei frame.
6. **Futuro quantistico:** Grover dimezza i bit di sicurezza di AES-256 (restano 128) e accelera poco Argon2 (resta legato alla memoria). Per le chiavi pubbliche c'è già X-Wing.

Fuori ambito: malware sul Mac dell'utente (legge la password mentre la si scrive) e coercizione.

## 4. Quanto regge una password oggi

Un tentativo con il profilo standard muove circa `t × m × 2 ≈ 3 × 256 MiB × 2 ≈ 1,5 GiB` di memoria. Con circa 1 TB/s di banda, una GPU di fascia alta arriva **al massimo a qualche centinaio di tentativi al secondo**: qui si assumono 500/s, una stima a favore dell'attaccante. Mille GPU fanno quindi circa 5 × 10⁵ tentativi al secondo.

| Entropia effettiva | Esempio | 1 GPU | 1000 GPU |
|---:|---|---:|---:|
| 30 bit | parola comune con varianti, «Estate2026!» | ~25 giorni | ~35 minuti |
| 40 bit | frase breve, password «buona» per i misuratori ingenui | ~70 anni | ~25 giorni |
| 50 bit | 4 parole casuali (Diceware) | ~70 000 anni | ~70 anni |
| 60 bit | 10 caratteri casuali alfanumerici | ~7 × 10⁷ anni | ~73 000 anni |
| 77 bit | 6 parole casuali (Diceware) | — | ~10¹⁰ anni |

Il profilo «forte» proposto (1 GiB, t=4: circa 8 GiB per tentativo, 5–6 volte il costo attuale) **sposta ogni riga di poco più di 2 bit**. Serve, ma una password da 30 bit non diventa sicura. Sotto i 40 bit nessun KDF ragionevole basta.

Il punto debole attuale: il misuratore dell'app (`StrengthMeter`) calcola `lunghezza × log2(alfabeto)`. Così «Password2026!» ottiene circa 85 bit, «Ottima», mentre in un dizionario con regole cade in pochi tentativi.

## 5. Proposte

### P1. Password migliori, senza cambiare il formato (alto valore, basso costo)

- **Stima realistica dell'entropia,** al posto del conteggio delle classi di caratteri:
  - un modello alla zxcvbn: dizionari di password comuni, nomi, parole italiane e inglesi, tastiere, date, sostituzioni l33t e ripetizioni. Il risultato si mostra come tempo stimato contro 1000 GPU;
  - zxcvbn è MIT, ma è codice esterno: serve l'approvazione. In alternativa si scrive uno stimatore nostro con un elenco di password comuni.
- **Generatore di passphrase** nel foglio password: 6 parole da un elenco Diceware (EFF large wordlist, CC-BY 3.0; un elenco italiano è da valutare), 77 bit, con copia negli appunti e nel Portachiavi.
- **Soglia:** sotto ~45 bit stimati, gli XIZ con sola password chiedono una conferma esplicita («questa password si indovina in giorni con hardware noleggiabile»). Il CLI rifiuta senza `--weak-password-ok`.
- **Normalizzazione Unicode della password** (NFC) prima di Argon2id. Oggi si usano i byte UTF-8 così come arrivano, quindi la stessa password digitata in NFD su un altro sistema non apre l'archivio. È un problema di interoperabilità più che di sicurezza, ma va fissato nella spec con una versione minore.

### P2. Un secondo fattore per la password (formato 1.14, valore alto)

Nuovo tipo di stanza: **password + segreto**.
- `KEK = HKDF-SHA-256(Argon2id(password) ‖ S, salt = archive_id, info "xiz/1.14/password+secret")`.
- `S` è uno di questi:
  - un **file chiave** da 32 byte (anche su una chiavetta);
  - un segreto nel **Portachiavi** con Touch ID, già usato per le identità;
  - un segreto sbloccato dal **Secure Enclave**: ECDH P-256 con una chiave che non lascia il chip.
- Chi ruba solo il file non può attaccare la password, perché manca `S`. Chi ruba solo `S` deve ancora indovinare la password.
- Rispetto ai destinatari a chiave pubblica che XIZ ha già, si conserva il modello mentale «metto una password».
- Variante hardware più forte: un **destinatario Secure Enclave** (stanza tipo 8), P-256 ECDH nel chip più ML-KEM-768 in software, combinati come X-Wing. La forza bruta è impossibile, ma la chiave si perde con il Mac, quindi va affiancata da una seconda stanza di recupero (soglia o chiave stampata).

### P3. Profili KDF più pesanti e calibrati (nessun cambio di formato)

- I limiti dei lettori ammettono già fino a 2 GiB e 10 passaggi.
- Profili:
  - **Standard** (256 MiB, t=3) resta il predefinito;
  - **Forte** (1 GiB, t=4, ~1 s);
  - **Archivio a lungo termine** (2 GiB, t=6, ~3 s).
- **Calibrazione** alla prima scelta: si misura sul Mac e si sceglie il profilo che sta nel tempo voluto. Prima di proporre un profilo si controlla la RAM libera, così l'apertura non fallisce su Mac con 8 GB.
- Va detto chiaramente all'utente: vale circa 2–3 bit. Il profilo da solo non sostituisce P1.

### P4. Key commitment (formato 1.14)

- AES-GCM non «impegna» la chiave: si possono costruire dati che si decifrano correttamente con due chiavi diverse (*invisible salamanders*; Len, Grubbs, Ristenpart, «Partitioning Oracle Attacks», USENIX Security 2021).
- In XIZ un mittente malevolo può avvolgere **chiavi del file diverse** per destinatari diversi: A e B aprono lo «stesso» archivio e vedono contenuti diversi. Oggi questo si scopre solo se l'archivio è firmato.
- Rimedio: un valore `commit = HKDF-SHA-256(file key, salt = archive_id, info "xiz/1.14/commit")` (32 byte) nel blocco delle chiavi, autenticato dall'AEAD di ogni stanza. Ogni lettore lo ricalcola dopo aver tolto l'involucro e rifiuta se non coincide.
- Costo: 32 byte e una HKDF, e libxiz va aggiornato. I lettori 1.13 lo ignorano senza danni (campo nuovo in una stanza o nel blocco, versione minore).

### P5. Avvisi e politiche (nessun cambio di formato)

- **Parametri deboli** all'apertura: se una stanza password usa meno di 64 MiB o t=1 (possibile con altri writer), l'inspector avvisa e propone «Cifra di nuovo con parametri standard». La conversione esiste già: si riscrive la stanza.
- **Stanze di peso diverso:** l'attaccante sceglie sempre la più debole. Il writer usa gli stessi parametri per tutte le stanze password di un archivio e lo controlla nei gruppi di accesso.
- **Ritorno a una versione precedente:** troncare un archivio a un footer precedente produce un archivio valido (§11, «Versions»), per costruzione. Contro un rollback silenzioso:
  - con le firme, mostrare «ultima versione firmata: N, del giorno X»;
  - senza firme, ricordare nel Portachiavi l'ultima versione vista di ogni `archive_id` e avvisare se ne compare una più vecchia. È un'idea per l'app, senza cambiare il formato.
- **Riempimento (padding) delle dimensioni,** opzionale (schema Padmé: al più +12%), per non rivelare la dimensione esatta del contenuto dai frame visibili. Valore basso per un archiviatore, utile per i file singoli.

### P6. Già a posto, da non cambiare

- Nessun verificatore della password più veloce del KDF, e parametri autenticati: da conservare in ogni versione futura.
- Limiti dei lettori sui parametri: tengono contro il DoS e restano compatibili con i profili più pesanti.
- Nonce dei frame dagli indici, con chiavi che dipendono da `archive_id`: niente riuso tra archivi, né tra segmenti (§11).
- Quantistico: AES-256 e Argon2id restano adeguati; per le chiavi pubbliche c'è X-Wing.

## 6. Piano proposto

| Fase | Contenuto | Formato | Serve |
|---|---|---|---|
| **A** | Stima dell'entropia, generatore di passphrase, soglia con conferma, `--weak-password-ok` | — | approvare zxcvbn o scrivere uno stimatore nostro; elenco di parole Diceware (CC-BY) |
| **B** | Profili Forte e Lungo termine con calibrazione; avviso sui parametri deboli e «Cifra di nuovo» | — | — |
| **C** | XIZ 1.14: key commitment, normalizzazione NFC della password, stanza password + segreto (file, Portachiavi) | 1.14 | aggiornare spec, Xipper e libxiz; fixture |
| **D** | Destinatario Secure Enclave (P-256 nel chip + ML-KEM-768), con stanza di recupero obbligatoria | 1.14 | prova su Mac veri (Touch ID) |
| **E** | Avviso di versione più vecchia (Portachiavi), padding opzionale | — / 1.14 | — |

**Stato (16/11/2026):** il proprietario ha scelto A e C, fatte nella 3.5 ([ROADMAP](ROADMAP.md)), poi B in forma ridotta (profilo Forte, avviso sui parametri deboli, rekey sul posto; niente calibrazione né profilo lungo termine). D rinviata: per il secondo fattore senza file conviene tenere il `.xizfactor` nel Portachiavi. Il fattore della stanza 8 è un file `.xizfactor`; Portachiavi e Secure Enclave restano per dopo.

Ordine consigliato: A → C (commitment e NFC) → B → C (password + segreto) → D → E. Le fasi A e B danno quasi tutto il guadagno contro la forza bruta senza toccare il formato. Il key commitment invece chiude una debolezza del formato, anche se poco probabile nella pratica.

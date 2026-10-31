# Studio: firme elettroniche con valore legale in Xipper

> Data: 31/10/2026. Stato: studio, nessuna decisione presa.
> Domanda: Xipper può fare qualcosa di simile a DocuSign, InfoCert GoSign, Namirial o Aruba Firma, cioè produrre o verificare firme elettroniche con valore legale? Fino a che livello da solo, e con chi deve appoggiarsi per gli altri?
> Le fonti sono in fondo a ogni sezione. I prezzi sono indicativi e vanno riverificati prima di qualsiasi decisione: molti sono di rivenditori.

---

## 0. In breve

- **Xipper da solo** può arrivare alla **firma elettronica semplice (SES)** subito e, con un'identità verificata del firmatario, alla **firma elettronica avanzata (AdES)** ai sensi dell'art. 26 eIDAS. Il valore probatorio resta però "liberamente valutabile dal giudice" (CAD art. 20 c. 1-bis), salvo che la soluzione sia una **FEA** conforme al DPCM 22/02/2013, che in Italia ha regole proprie e vale solo tra firmatario ed erogatore.
- **La firma qualificata (QES, in Italia "firma digitale")** richiede sempre un **certificato qualificato** emesso da un **QTSP** e una chiave in un **dispositivo qualificato (QSCD)**: smart card, token o HSM remoto del QTSP. Xipper non può produrla da solo, ma può **usarla**: con la smart card dell'utente (CNS, token InfoCert/Aruba/Namirial) o con la **firma remota** di un QTSP tramite l'**API CSC**.
- Per un archiviatore il formato giusto è **ASiC-E** (ETSI EN 319 162-1): un contenitore **ZIP** con dentro i file e una firma CAdES o XAdES che li copre tutti. Xipper sa già scrivere ZIP.
- Ordine consigliato: (1) **verificare** `.p7m`, PAdES e ASiC con la Trusted List UE; (2) **firmare con smart card** in CAdES/ASiC; (3) **marca temporale qualificata** italiana nella cronologia XIZ; (4) **firma remota CSC** con un QTSP; (5) solo dopo, eventualmente, un flusso multi-firmatario stile DocuSign.
- **Cosa non fare**: diventare QTSP, chiamare "firma digitale" le firme Ed25519 di XIZ, costruire un servizio cloud che tiene chiavi o documenti sanitari di terzi.

---

## 1. Quadro giuridico

### 1.1 eIDAS (Reg. UE 910/2014) e eIDAS 2 (Reg. UE 2024/1183)

| Livello | Definizione (eIDAS art. 3) | Requisiti | Effetto giuridico |
|---|---|---|---|
| **SES** firma elettronica semplice | dati in forma elettronica allegati o connessi ad altri dati, usati per firmare (art. 3 n. 10) | nessuno | non può essere negata efficacia solo perché elettronica (art. 25 c. 1) |
| **AdES** firma elettronica avanzata | art. 3 n. 11 + **art. 26** | a) connessa unicamente al firmatario; b) idonea a identificarlo; c) creata con dati che il firmatario può usare sotto il proprio controllo esclusivo, con elevato livello di sicurezza; d) collegata ai dati in modo da rilevare ogni modifica successiva | come SES; il valore lo stabilisce il diritto nazionale |
| **QES** firma elettronica qualificata | AdES + **certificato qualificato** (All. I) + **QSCD** (All. II) | QTSP iscritto nella Trusted List; dispositivo certificato | **equivalente alla firma autografa** (art. 25 c. 2); riconosciuta in tutti gli Stati membri (art. 25 c. 3) |
| **Sigillo** semplice / avanzato / qualificato | come le firme, ma di una **persona giuridica** (art. 3 nn. 25–27, art. 36) | sigillo qualificato: certificato qualificato di sigillo + QSCD | presunzione di integrità e di correttezza dell'origine (art. 35 c. 2) |
| **Validazione temporale** semplice / qualificata | art. 3 nn. 33–34, art. 42 | qualificata: QTSP, ora UTC, firma con chiave del QTSP | presunzione di accuratezza di data e ora e di integrità dei dati (art. 41 c. 2) |

Altri punti utili:
- **Validazione** di una QES: requisiti all'art. 32; servizio di validazione qualificato all'art. 33; **conservazione** qualificata delle firme all'art. 34.
- **Trusted List**: ogni Stato pubblica l'elenco dei suoi QTSP (art. 22); la Commissione pubblica la lista delle liste (**LOTL**). Chi valida una QES verifica che il certificato risalga a un servizio qualificato in quelle liste alla data della firma.
- **Non serve alcun accreditamento per firmare** né per scrivere un software di firma. Serve per *essere* un QTSP (audit di conformità biennale, art. 20, vigilanza AgID in Italia).

**eIDAS 2** (Reg. 2024/1183, in vigore dal 20/05/2024) aggiunge:
- il **Portafoglio europeo di identità digitale (EUDI Wallet)**, art. 5a: ogni Stato deve renderne disponibile almeno uno entro 24 mesi dagli atti di esecuzione (adottati a fine 2024, quindi verso fine 2026). Il wallet deve permettere di **firmare con QES gratuitamente**, con facoltà degli Stati di limitarlo agli usi non professionali (art. 5a c. 5 lett. g). In Italia il canale è l'app IO / IT-Wallet.
- **Firme e sigilli remoti** qualificati gestiti dal QTSP per conto del firmatario (art. 29a, 39a): consolida il modello "chiave nell'HSM del QTSP" già usato da tutti.
- nuovi servizi fiduciari qualificati: **archiviazione elettronica** (artt. 45i–45j), **registri elettronici** (artt. 45k–45l), attestazioni elettroniche di attributi.

Per Xipper il wallet è interessante a medio termine: se gli wallet esporranno la firma tramite API standard (il CSC lavora al raccordo con OpenID4VP), un'app macOS potrà chiedere una QES gratuita al wallet dell'utente senza contratto con un QTSP. Oggi non è ancora utilizzabile in produzione.

### 1.2 Italia: CAD, AgID, FEA

| Norma | Cosa dice | Conseguenza pratica |
|---|---|---|
| **CAD art. 20 c. 1-bis** | il documento soddisfa la **forma scritta** e ha l'efficacia dell'**art. 2702 c.c.** (scrittura privata) se firmato con firma digitale, altra FEQ, **FEA**, oppure con un processo AgID che identifica il firmatario (es. **firma con SPID**); altrimenti idoneità e valore probatorio sono **liberamente valutabili** dal giudice | una firma XIZ "nuda" (SES) è liberamente valutabile |
| **CAD art. 21 c. 2-bis** | le scritture dell'art. 1350 nn. 1–12 c.c. (immobili, ecc.) richiedono **a pena di nullità** FEQ o firma digitale; gli altri atti a forma scritta (n. 13) anche FEA | per contratti immobiliari solo QES |
| **CAD art. 24** | firma digitale: certificato qualificato non scaduto, non revocato né sospeso; la firma con certificato revocato/scaduto equivale a mancata sottoscrizione salvo che una **validazione temporale opponibile** provi che è anteriore (c. 4-bis) | serve la marca temporale per la validità a lungo termine |
| **DPCM 22/02/2013**, artt. 55–61 | regole tecniche della **FEA**: identificazione certa del firmatario, connessione univoca firma-firmatario, controllo esclusivo, integrità, possibilità di vedere cosa si firma, connessione univoca firma-documento (art. 56); l'erogatore deve identificare l'utente con documento valido, conservare la documentazione per **20 anni**, avere un'**assicurazione** di almeno 500.000 € e pubblicare una descrizione tecnica (art. 57); la FEA vale solo nei rapporti tra firmatario ed erogatore (art. 60) | una FEA "di Xipper" ha senso solo se GenomeUp (o un cliente) la eroga ai propri pazienti/clienti, con obblighi organizzativi |
| **Linee guida AgID art. 20 CAD** (Det. 157/2020) | firma con **SPID**: l'identity provider SPID firma per conto dell'utente dopo l'autenticazione; il documento ha l'efficacia del 1-bis | richiede di essere service provider SPID e di offrire anche la QES |
| **CIE / CieSign** | app del Poligrafico (IPZS): **FEA gratuita** con la CIE via NFC | la CIE **non** contiene un certificato di firma qualificata; non è una QES |
| **Det. AgID 121/2019** | regole tecniche per certificati qualificati, firme e marche: formati ammessi CAdES, PAdES, XAdES (profili baseline ETSI) | è la ragione per cui il `.p7m` è lo standard italiano |
| **Linee guida AgID su formazione, gestione e conservazione** (2021) | conservazione a norma: manuale, responsabile, pacchetti di versamento/archiviazione/distribuzione, conservatori iscritti al marketplace AgID/ACN | Xipper **non** è un sistema di conservazione; può al più preparare pacchetti da versare |

Sanità: referti e documenti clinici con valore legale sono in genere firmati con **firma digitale (QES)** del medico, spesso in remoto con firma massiva via HSM. Per GenomeUp questo significa che un referto genomico firmato in Xipper con Ed25519 **non** sostituisce la firma digitale del medico.

### 1.3 Cosa può raggiungere Xipper

| Livello | Da solo? | Cosa manca |
|---|---|---|
| SES | **Sì, oggi** (XIZ 1.3 §13.5) | nulla |
| AdES (art. 26 eIDAS) | **Quasi** | un legame verificato tra chiave e persona (certificato X.509 di una CA, anche non qualificata, o identificazione documentata); chiave sotto controllo esclusivo con "elevato livello di sicurezza" (Secure Enclave) |
| FEA italiana (DPCM 2013) | Solo come **software di un erogatore** | identificazione con documento, assicurazione, conservazione ventennale, nota tecnica pubblicata: obblighi organizzativi, non di codice |
| Firma con SPID (art. 20 c. 1-bis) | No | essere service provider SPID |
| QES / firma digitale | **No** | certificato qualificato + QSCD di un QTSP: Xipper può usare smart card o API remote |
| Sigillo qualificato | No | certificato qualificato di sigillo per GenomeUp (acquistabile da un QTSP) |
| Marca temporale qualificata | No, ma **può chiederla** | contratto/pacchetto con una TSA qualificata (RFC 3161, già supportato) |

**Fonti §1**: [Reg. UE 910/2014 (EUR-Lex)](https://eur-lex.europa.eu/legal-content/IT/TXT/?uri=CELEX:32014R0910) · [Reg. UE 2024/1183 (EUR-Lex)](https://eur-lex.europa.eu/legal-content/IT/TXT/?uri=CELEX:32024R1183) · [CAD, D.Lgs. 82/2005 (Normattiva)](https://www.normattiva.it/uri-res/N2Ls?urn:nir:stato:decreto.legislativo:2005-03-07;82) · [DPCM 22/02/2013 (GU n. 117/2013)](https://www.gazzettaufficiale.it/eli/id/2013/05/21/13A04284/sg) · [AgID, Tipologie di firme e sigilli elettronici (2019)](https://www.agid.gov.it/sites/default/files/repository_files/tipologie_di_firme_e_sigilli_elettronici_v1_dicembre_2019.pdf) · [AgID, linee guida firma con SPID (2020)](https://www.agid.gov.it/it/agenzia/stampa-e-comunicazione/notizie/2020/03/26/spid-emanate-linee-guida-firmare-i-documenti-online) · [Ministero dell'Interno, Firma con CIE – CieSign](https://www.cartaidentita.interno.gov.it/en/public-and-business-administration/electronic-signature-with-cie-ciesign/) · [CSC, white paper EUDI Wallet e firma remota](https://cloudsignatureconsortium.org/wp-content/uploads/2024/10/CSC-White-Paper-The-EU-digital-identity-wallet-a-new-tool-for-remote-signing-with-qualified-electronic-signatures.pdf) · [EU Trusted List Browser](https://eidas.ec.europa.eu/efda/tl-browser/)

---

## 2. Come funzionano i servizi commerciali

### 2.1 Schema comune

Tutti i servizi (DocuSign, Adobe Acrobat Sign, InfoCert GoSign, Namirial eSignAnyWhere, Aruba Firma Remota, Intesi Group) seguono lo stesso schema:

1. **Busta (envelope)**: uno o più documenti, l'elenco dei firmatari con ordine (sequenziale o parallelo), i campi di firma, le scadenze, i promemoria.
2. **Invito**: email/SMS con link; il firmatario apre il documento nel browser.
3. **Identificazione**, secondo il livello richiesto:
   - SES: solo il link email (eventualmente codice di accesso);
   - AdES/FEA: **OTP via SMS**, SPID, CIE, documento + selfie con verifica di vitalità;
   - QES: **identificazione forte** prima di emettere il certificato: SPID livello 2, CIE, firma digitale esistente, **video-riconoscimento** (operatore o automatico).
4. **Firma**:
   - SES/AdES: il servizio applica al PDF un **sigillo** del fornitore (non una firma del firmatario) e registra le prove;
   - QES: il QTSP genera la chiave del firmatario in un **HSM certificato QSCD** e la attiva con un fattore che controlla solo il firmatario (PIN + OTP o app). Spesso il certificato è **"one-shot"**: emesso per quella sola transazione, valido minuti o un'ora, poi la chiave è distrutta.
5. **Audit trail** (DocuSign: *Certificate of Completion*): registro di eventi (invio, apertura, IP, user agent, orari, metodo di identificazione, hash del documento), sigillato con il sigillo del fornitore e marcato temporalmente, allegato o conservato.
6. **Chiusura**: il PDF finale riceve un **sigillo** del fornitore con marca temporale (PAdES B-LT o B-LTA), così ogni modifica successiva è visibile.

Il valore legale non sta nel flusso (che è commodity) ma in tre cose: **identità verificata**, **chiave in un QSCD sotto controllo del firmatario**, **certificato in una Trusted List**. DocuSign stesso è iscritto nella Trusted List UE come QTSP e per la QES usa la sua verifica d'identità ("ID Verification for EU Qualified") o un QTSP partner.

### 2.2 Firma remota e API CSC

La **Cloud Signature Consortium API** (v2.0 nel 2022–2023, **v2.2 del 6/11/2025**) è lo standard aperto per chiedere a un QTSP una firma remota. Fra i membri ci sono Adobe, **InfoCert** e **Intesi Group**. Il flusso, in sintesi:

| Passo | Endpoint CSC v2 | Note |
|---|---|---|
| Scoperta | `POST /csc/v2/info` | metodi di autenticazione supportati, URL OAuth2 |
| Accesso al servizio | OAuth2 *authorization code* con scope `service` (o `auth/login`) | l'utente si autentica presso il QTSP nel browser |
| Elenco credenziali | `credentials/list`, `credentials/info` | certificato, catena, algoritmi, tipo di autorizzazione (PIN, OTP, app) |
| Autorizzazione | OAuth2 con scope `credential` **con gli hash** da firmare, oppure `credentials/authorize` con PIN/OTP | livello **SCAL2**: l'autorizzazione è legata agli hash specifici, requisito per la QES remota |
| Firma | `signatures/signHash` (il client calcola l'hash e costruisce CAdES/XAdES/PAdES) o `signatures/signDoc` (il QTSP costruisce la firma) | con `signHash` il documento non lascia mai il Mac: **ottimo per dati sanitari** |
| Marca | `signatures/timestamp` (v2) oppure TSA RFC 3161 separata | |

Disponibilità presso i QTSP italiani (da verificare commercialmente):

| QTSP | API per integratori | CSC | Note |
|---|---|---|---|
| **InfoCert** (Tinexta) | portale developers.infocert.digital, eSignature API | membro e promotore CSC | GoSign come prodotto finale; firma remota venduta anche via rivenditori (~**25,70 € + IVA**/anno per certificato remoto, rinnovo da ~9 €) |
| **Namirial** | **SWS** (SOAP e REST): CAdES/PAdES/XAdES, marche, verifica, firma remota con OTP | supporto CSC non documentato pubblicamente | eSignAnyWhere per i flussi multi-firmatario |
| **Aruba** | **ARSS** (Aruba Remote Signing Service), SOAP, OTP | non documentato pubblicamente | molto diffuso in sanità e PA; esempi di integrazione di terzi |
| **Intesi Group** | PkBox, Time4Mind | membro CSC | orientato all'integrazione enterprise |
| Altri (Poste, InfoCamere, Uanataca, Bit4id) | vari | da verificare | |

Costi tipici osservati (indicativi): certificato di firma remota per persona 20–40 €/anno; one-shot da pochi euro a firma in convenzione; marche temporali a pacchetti (20–500 000 unità); sigillo qualificato aziendale qualche centinaio di euro/anno più canone HSM. Per un'integrazione B2B (firma massiva, one-shot, sandbox) serve un **contratto** col QTSP: i listini pubblici non coprono questi casi.

**Fonti §2**: [CSC, introduzione all'API v2.2](https://cloudsignatureconsortium.org/resources/csc-api-v2-2/) · [CSC API v2.0.0.2 (PDF)](https://cloudsignatureconsortium.org/wp-content/uploads/2023/04/csc-api-v2.0.0.2.pdf) · [CSC, membri](https://cloudsignatureconsortium.org/membership/) · [InfoCert Developers – Signature Solutions](https://developers.infocert.digital/?p=3966) · [InfoCert, PKI Disclosure Statement](https://qtsp.infocert.it/pdf/ICERT_INDI_PDS.pdf) · [Openapi, firma qualificata InfoCert (prezzo rivenditore)](https://openapi.com/products/infocert-qualified-electronic-signature) · [Namirial SWS, documentazione](https://docs.namirial.app/products/sws/homepage) · [Namirial SWS Integration Guide](https://docs.namirial.app/products/sws/customer_documentation/integration) · [Esempio ARSS Aruba (Chilkat)](https://www.example-code.com/cpp/arss_sign_pdf.asp) · [DocuSign Community, QES e QTSP](https://community.docusign.com/esignature-111/how-to-get-a-qes-through-docusign-i-understand-docusign-is-a-qtps-26796)

---

## 3. Formati di firma

### 3.1 Famiglie ETSI

| Formato | Norma ETSI | Cosa firma | Estensione | Uso in Italia |
|---|---|---|---|---|
| **CAdES** | EN 319 122-1/-2 | qualsiasi file; busta CMS (RFC 5652) | `.p7m` (attached), `.p7s` (detached) | **lo standard di fatto**: "file.pdf.p7m" |
| **PAdES** | EN 319 142-1/-2 | PDF, firma dentro il file | `.pdf` | molto diffuso, leggibile in Acrobat |
| **XAdES** | EN 319 132-1/-2 | XML (FatturaPA, CDA2 sanitari) | `.xml` | fatture, documenti clinici HL7 CDA |
| **JAdES** | TS 119 182-1 | JSON (JWS) | `.json` | nuovo, legato al mondo API e wallet |
| **ASiC-S / ASiC-E** | **EN 319 162-1/-2** | **contenitore ZIP** con 1 (S) o N (E) file e firme CAdES o XAdES | `.asics`, `.asice` (`.scs`, `.sce`) | previsto dalla Det. AgID 121/2019 ma poco usato in Italia; standard in Estonia, Lettonia, Lituania, Finlandia |

**ASiC-E** in dettaglio, perché è il punto d'incontro naturale con un archiviatore:
- è uno ZIP con primo file `mimetype` non compresso (`application/vnd.etsi.asic-e+zip`), come EPUB e ODF;
- in `META-INF/` stanno le firme: `signatures*.xml` (XAdES) oppure `signature*.p7s` (CAdES) con un **manifest** `ASiCManifest*.xml` che elenca i file firmati e i loro digest;
- più firmatari possono aggiungere firme indipendenti **senza toccare i file**; si possono aggiungere marche (`timestamp*.tst`) ed evidence record (ERS, RFC 4998) per la conservazione a lungo termine.

### 3.2 Livelli baseline

| Livello | Contenuto aggiunto | A cosa serve |
|---|---|---|
| **B-B** | firma + certificato del firmatario negli attributi firmati | firma di base |
| **B-T** | **marca temporale** sulla firma | prova che la firma esisteva prima di una data (CAD art. 24 c. 4-bis) |
| **B-LT** | catena di certificati + **OCSP/CRL** incorporati | verificabile anche quando la CA non risponde più |
| **B-LTA** | **marca d'archivio** su tutto, rinnovabile | resiste a scadenza dei certificati della TSA e ad algoritmi indeboliti |

### 3.3 Validazione

Validare una QES (eIDAS art. 32; ETSI EN 319 102-1 per l'algoritmo; TS 119 172-4 per la politica) significa:
1. ricostruire la catena fino a un **servizio qualificato** in una Trusted List nazionale, scaricata dalla **LOTL** della Commissione (XML firmato XAdES; va verificata la firma della lista stessa con i certificati pubblicati nella Gazzetta UE);
2. controllare lo stato del certificato **alla data della firma** (OCSP/CRL, oppure quelli incorporati in B-LT);
3. controllare i qualificatori del certificato (QcStatements: `QcCompliance`, `QcSSCD`/QSCD, tipo firma o sigillo);
4. controllare la marca temporale e gli algoritmi (ETSI TS 119 312);
5. produrre un **rapporto di validazione** (TOTAL-PASSED / INDETERMINATE / TOTAL-FAILED, ETSI TS 119 102-2).

Lo strumento di riferimento è **DSS** (Digital Signature Service) della Commissione europea: libreria **Java, LGPL 2.1**, che crea e valida CAdES, PAdES, XAdES, JAdES e ASiC-S/E, gestisce Trusted List e LOTL e implementa EN 319 102-1. È la base di molti verificatori, compresi servizi commerciali.

**Fonti §3**: [ETSI EN 319 162-1 (ASiC)](https://www.etsi.org/deliver/etsi_en/319100_319199/31916201/) · [ETSI EN 319 122-1 (CAdES)](https://www.etsi.org/deliver/etsi_en/319100_319199/31912201/) · [ETSI EN 319 142-1 (PAdES)](https://www.etsi.org/deliver/etsi_en/319100_319199/31914201/) · [ETSI EN 319 132-1 (XAdES)](https://www.etsi.org/deliver/etsi_en/319100_319199/31913201/) · [ETSI EN 319 102-1 (validazione)](https://www.etsi.org/deliver/etsi_en/319100_319199/31910201/) · [DSS, documentazione](https://ec.europa.eu/digital-building-blocks/DSS/webapp-demo/doc/dss-documentation.html) · [DSS, pagina del progetto](https://ec.europa.eu/digital-building-blocks/sites/display/DIGITAL/Digital%20Signature%20Service%20-%20%20DSS) · [AgID, regole tecniche firme (Det. 121/2019)](https://www.agid.gov.it/it/piattaforme/firma-elettronica-qualificata)

---

## 4. Opzioni concrete per Xipper

Le stime sono giornate di sviluppo per una persona, con l'aiuto di Claude, sullo stile delle stime in [STUDIO.md](../STUDIO.md). Non includono test con QTSP reali né consulenza legale.

### 4.1 Riepilogo

| Opzione | Livello legale ottenuto | Effort | Costi esterni | Rischio | Valore per l'utente |
|---|---|---|---|---|---|
| **a. Verifica** `.p7m`, PAdES, ASiC con Trusted List | nessuno (verifica) | 15–25 g base; 40–60 g per una validazione EN 319 102-1 seria | 0 | medio (risultati sbagliati) | **alto**: aprire e verificare i `.p7m` è un bisogno quotidiano in Italia |
| **b. Creare ASiC-E** con CAdES/XAdES | come la chiave usata | 10–15 g | 0 | basso | medio, alto se unito a c/d |
| **c. Firma con smart card** (CNS, token) | **QES** (firma digitale) | 15–25 g | 0 (l'utente ha già il dispositivo) | medio (driver, PIN) | **alto** per professionisti italiani |
| **d. Firma remota CSC** con QTSP | **QES** | 20–30 g per un QTSP, +5–10 g ciascuno dopo | contratto QTSP; 20–40 €/anno per utente | medio-alto (contratti, OAuth) | alto |
| **e. Flusso multi-firmatario** su XIZ | SES/AdES; QES se ogni firmatario usa c o d | 30–50 g | 0, o sigillo qualificato ~ centinaia €/anno | alto (prodotto diverso, serve un server) | da validare |
| **f. Marca temporale qualificata** | marca qualificata (art. 41) | 2–4 g (RFC 3161 già c'è) | pacchetti di marche | basso | medio-alto, costo basso |
| **g. XIZ come AdES** | AdES difendibile | 10–20 g + parere legale | 0 | medio (affermazioni legali) | medio |

### 4.2 (a) Verifica di `.p7m`, PAdES e ASiC

Cosa serve:
- **Parsing CMS/ASN.1**: Swift ha `swift-asn1` e `swift-certificates` (Apple, Apache 2.0), che coprono X.509 e una parte di CMS; Security.framework verifica catene ma non conosce Trusted List né QcStatements. Xipper già verifica `TimeStampToken` RFC 3161 (CMS), quindi la base c'è.
- **Estrazione** del contenuto dei `.p7m` (anche annidati: `.p7m.p7m` con più firme) e anteprima: è il caso d'uso più richiesto ed è facile.
- **Trusted List**: scaricare la LOTL, verificarne la firma XAdES, scaricare le liste nazionali, metterle in cache con data; senza XAdES nativo serve un verificatore XML-DSig minimo (C14N è la parte fastidiosa).
- **Revoca**: OCSP e CRL in rete (Xipper oggi non si collega in rete senza consenso: va chiesto, come per la TSA) oppure solo i dati incorporati (B-LT).
- **PAdES**: leggere `/ByteRange` e `/Contents` del PDF; PDFKit non verifica le firme, ma l'estrazione del CMS è semplice.

Due strade:
1. **Reimplementazione Swift parziale** (consigliata per partire): "firma integra, firmatario X, certificato emesso da Y, Y è qualificato nella lista italiana, marca del giorno Z". Non pretendere la conformità a EN 319 102-1: mostrare sempre "verifica informativa, non validazione qualificata". 15–25 g.
2. **DSS completo**: Java, quindi JVM nel bundle (100+ MB) o un servizio esterno; contrario alla filosofia "tutto nativo, niente dipendenze" di Xipper. Si può usare **come oracolo nei test**: confrontare i risultati della versione Swift con quelli di DSS su un corpus di file reali (deve restare fuori dal bundle).

Una reimplementazione completa di DSS in Swift è un progetto di **mesi** (DSS ha oltre dieci anni di lavoro e casi limite di centinaia di firme reali): da evitare.

### 4.3 (b) Creare contenitori ASiC-E

Xipper ha già lo ZIP writer. Mancano: `mimetype` in testa non compresso, `META-INF/ASiCManifest.xml`, `META-INF/signature001.p7s` (CAdES detached sul manifest). La variante **CAdES** è preferibile alla XAdES perché evita la canonicalizzazione XML e riusa il codice CMS. Il formato è aperto, verificabile con DSS e con i verificatori europei; in Italia meno noto, quindi utile offrire anche il classico **`.zip.p7m`** (CAdES attached sullo ZIP) che Dike, GoSign e ArubaSign aprono ovunque.

Vantaggio rispetto a XIZ: un destinatario **senza Xipper** può verificare. XIZ resta il formato per la cronologia firmata e la cifratura; ASiC-E è il formato "da consegnare".

### 4.4 (c) Smart card e token italiani su macOS

- Le carte di firma italiane (CNS con certificato di firma, token USB di InfoCert, Aruba, Namirial, Bit4id, Actalis) espongono la chiave tramite **PKCS#11** (middleware del produttore, es. `libbit4xpki.dylib` di Bit4id) e in parte tramite **CryptoTokenKit**, l'interfaccia nativa di macOS. Con CryptoTokenKit la chiave compare come `SecKey` di un token e si firma con `SecKeyCreateSignature`; il PIN lo chiede il sistema.
- **CIE**: utile per autenticazione e per la FEA CieSign, **non** per la QES (la CIE non ha certificato di firma qualificata).
- Problemi pratici: middleware diversi per marca, driver CCID, carte che CryptoTokenKit non vede senza il plug-in del produttore. PKCS#11 diretto (`dlopen` della libreria scelta dall'utente) è più universale ma va fatto in C dentro Swift.
- Algoritmi: le carte e gli HSM firmano in **RSA 2048/3072 o ECDSA P-256**, non Ed25519. La firma XIZ (oggi solo Ed25519, `algorithm = 1`) andrebbe estesa con un algoritmo "CMS/X.509" (vedi §4.8).
- **App non sandboxata e senza Developer ID**: per CryptoTokenKit e PKCS#11 va bene; nessun entitlement speciale per leggere token di sistema.

Risultato: **una vera firma digitale (QES)** in CAdES `.p7m` o ASiC-E, fatta con il dispositivo che l'utente ha già. È l'opzione col miglior rapporto valore/costo dopo la verifica.

### 4.5 (d) Firma remota tramite API CSC

- Implementare il **client CSC v2** (OAuth2 con `ASWebAuthenticationSession`, `credentials/list`, autorizzazione SCAL2 con gli hash, `signHash`). La firma si costruisce in locale: **il documento non lascia mai il Mac**, va al QTSP solo l'hash. Per dati sanitari e genomici è il punto più importante.
- Servono: account sandbox presso il QTSP, `client_id` OAuth registrato (di solito richiede un contratto), test di ogni metodo di autorizzazione (OTP SMS, app push).
- InfoCert e Intesi sono membri CSC e i candidati naturali; Aruba e Namirial hanno API proprietarie (ARSS, SWS): ogni API non-CSC costa altri 10–15 g.
- Alternativa senza contratto: molti utenti hanno già una firma remota personale (InfoCert, Aruba, Namirial, Poste). Se il QTSP espone CSC con registrazione aperta dei client, Xipper potrebbe usarla direttamente; altrimenti l'utente firma col software del QTSP e Xipper si limita a impacchettare e verificare.
- Modello di costo: il certificato lo paga l'utente al QTSP (20–40 €/anno); Xipper non incassa né rivende nulla, quindi non diventa un intermediario.

### 4.6 (e) Flusso multi-firmatario stile DocuSign su XIZ

XIZ 1.3 ha già quasi tutto il lato "prova": ogni segmento è firmato, la catena dei segmenti è verificabile, le marche RFC 3161 sono opzionali, le prove Merkle mostrano un singolo file. Un flusso "busta" potrebbe essere:

1. il mittente crea un `.xiz` con i documenti e un **manifest di busta** (firmatari attesi con chiave pubblica o certificato, ordine, scadenza) e lo firma;
2. ogni firmatario apre l'archivio, vede i documenti, e **aggiunge un segmento** che contiene solo la sua dichiarazione ("approvo i documenti con digest …") firmata con la sua chiave, con marca temporale;
3. l'ultimo segmento chiude la busta (sigillo dell'organizzazione).

Cosa dà legalmente:
- con chiavi Ed25519 autodichiarate: **SES**, liberamente valutabile;
- con identità verificata e chiave in Secure Enclave: **AdES** difendibile, ma **non** FEA italiana se manca l'erogatore con i suoi obblighi DPCM;
- con firma CMS da smart card o CSC in ciascun segmento: **QES per ciascun firmatario**.

Limiti: DocuSign funziona perché c'è un **server** che invia gli inviti, custodisce lo stato, registra gli eventi con orari affidabili e li sigilla. Senza server, la busta XIZ viaggia via email/file e l'"audit trail" sono solo le firme e le marche: utile, ma è un altro prodotto (B2B, con hosting, GDPR, SLA). Va fatto **solo dopo** c e d, e solo se GenomeUp ha un caso d'uso concreto (es. firma congiunta di un consenso o di un rilascio dati fra laboratorio e clinico).

### 4.7 (f) Marca temporale qualificata

Xipper già marca le firme dei segmenti con RFC 3161 (imprint = SHA-256 della firma, §13.5 della spec). Per renderla **qualificata** basta puntare a una TSA qualificata italiana (InfoCert, Aruba, Namirial, Intesa/IBM, Poste) con le credenziali dell'utente. Lavoro: autenticazione HTTP (Basic o certificato client) che le TSA italiane richiedono, verifica che il certificato della TSA sia nella Trusted List come servizio di validazione temporale qualificato (riusa §4.2), messaggio chiaro in UI. Le TSA dichiarano validità delle marche di 20 anni (InfoCert) e conservazione fino a 30 (Aruba); pacchetti acquistabili anche via rivenditori. È il passo più economico per dare a XIZ una data **opponibile** (eIDAS art. 41 c. 2, CAD art. 24 c. 4-bis).

### 4.8 (g) XIZ e i requisiti AdES (art. 26 eIDAS)

| Requisito art. 26 | XIZ 1.3 oggi | Cosa manca |
|---|---|---|
| a) connessa unicamente al firmatario | chiave Ed25519 per firmatario, chiave pubblica nel record di firma | nulla sul piano tecnico |
| b) idonea a identificare il firmatario | solo `label` **autodichiarato** e la lista di chiavi fidate locale | legare la chiave a un'identità: certificato X.509 (anche da CA non qualificata o aziendale) incorporato nel record, oppure firma CMS con certificato qualificato |
| c) dati di creazione sotto controllo esclusivo, elevato livello di sicurezza | chiave nel Portachiavi con Touch ID; Ed25519 però **non** è supportato dalla Secure Enclave, quindi la chiave è software ed esportabile da chi controlla il Mac | opzione **ECDSA P-256 in Secure Enclave** (non esportabile, Touch ID per ogni firma); oppure smart card / CSC |
| d) modifiche successive rilevabili | **sì**: hash di directory, catalogo e frame; catena delle firme; Merkle root firmata | nulla |

Proposta tecnica per una futura revisione della spec (non in questo studio): `algorithm = 2` ECDSA P-256 e `algorithm = 3` **"CMS"**, dove il campo firma contiene una SignedData CAdES (detached) sul messaggio di §13.5, con catena di certificati e, opzionalmente, marca e dati di revoca. Così un segmento XIZ può portare una **firma digitale italiana vera**, verificabile anche estraendo messaggio e `.p7s` e dandoli a DSS. È la mossa che unisce XIZ al mondo legale senza cambiare il resto del formato.

---

## 5. Raccomandazione

### 5.1 Roadmap a fasi

| Fase | Contenuto | Effort | Risultato |
|---|---|---|---|
| **F1** | Apertura ed estrazione `.p7m` (anche annidati), `.p7s`, ASiC-S/E; verifica crittografica e catena; anteprima del contenuto | 8–12 g | Xipper diventa utile ogni giorno a chiunque riceva `.p7m` in Italia |
| **F2** | Trusted List (LOTL + IT), qualificatori del certificato, marche; rapporto di verifica "informativo"; PAdES | 10–15 g | "Firma qualificata valida al giorno X" con avvertenze chiare; test di confronto con DSS |
| **F3** | Marca temporale qualificata da TSA italiane nella cronologia XIZ e sui `.p7m` | 2–4 g | data opponibile a basso costo |
| **F4** | Firma con smart card/token (CryptoTokenKit, poi PKCS#11): CAdES `.p7m`, ASiC-E, segmento XIZ con firma CMS (`algorithm = 3`) | 15–25 g | **firma digitale** vera da Xipper |
| **F5** | Client CSC v2 con un QTSP (InfoCert o Intesi), solo `signHash` | 20–30 g + contratto | firma digitale remota, documento sempre in locale |
| **F6** | (Opzionale) busta multi-firmatario su XIZ; ECDSA P-256 in Secure Enclave per l'AdES "senza QTSP" | 30–50 g | solo con caso d'uso GenomeUp concreto |

F1–F3 non richiedono contratti e sono coerenti con la filosofia di Xipper (nativo, locale, nessuna dipendenza). F4 porta il salto legale. F5 richiede un accordo commerciale. F6 è un prodotto diverso.

### 5.2 Rischi

- **Responsabilità per verifiche sbagliate**: dire "firma valida" su un file non valido (o viceversa) può avere conseguenze legali per l'utente. Mitigazione: etichetta "verifica informativa, non validazione qualificata ex art. 33 eIDAS", suite di test con DSS come oracolo, licenza MIT senza garanzia.
- **Accreditamento**: non serve per firmare né per scrivere software di firma; serve per **essere** QTSP (audit, HSM certificati, assicurazione, vigilanza AgID). GenomeUp non deve diventarlo.
- **FEA**: offrirla come "FEA ai sensi del DPCM 2013" crea obblighi da erogatore (identificazione, assicurazione 500 000 €, conservazione 20 anni). Non annunciarla senza decisione societaria e parere legale.
- **GDPR e dati sanitari** (art. 9 GDPR): con `signHash` e marche al QTSP/TSA va **solo un hash**, non dati personali del contenuto; va comunque informato l'utente delle connessioni di rete (Xipper oggi non si collega senza consenso). Un servizio cloud di buste, invece, renderebbe GenomeUp **responsabile del trattamento** di documenti clinici di terzi: DPIA, contratti ex art. 28, hosting UE.
- **Algoritmi**: Ed25519 è poco supportato da QSCD e verificatori italiani; non usarlo dove serve interoperabilità legale.
- **Distribuzione self-signed**: per un software di firma la fiducia conta; l'assenza di Developer ID può frenare clienti istituzionali. Da rivalutare se F4–F5 vanno avanti.
- **Mercato**: GoSign, Dike, ArubaSign, Firma4NG sono gratuiti o inclusi col certificato. Xipper vince solo se unisce firma, archivio, cifratura e cronologia, non come "un altro firmatore".
- **eIDAS 2 in movimento**: gli atti di esecuzione su wallet e firma remota cambiano nel 2025–2027; F5 va disegnata in modo da aggiungere il wallet come altro "fornitore di firma".

### 5.3 Cosa NON fare

- **Non diventare QTSP** né gestire chiavi di terzi su server propri.
- **Non chiamare "firma digitale"** o "firma qualificata" le firme Ed25519 di XIZ: sono SES (AdES al massimo, con identità verificata). Nell'interfaccia usare "firma dell'autore" o "firma elettronica".
- **Non reimplementare DSS** per intero in Swift, né includere una JVM nel bundle.
- **Non costruire una piattaforma cloud stile DocuSign** prima di avere un caso d'uso pagante: è un prodotto diverso, con obblighi GDPR pesanti per dati sanitari.
- **Non inviare documenti al QTSP** (`signDoc`) quando `signHash` basta.
- **Non presentare Xipper come sistema di conservazione a norma**: può preparare pacchetti firmati e marcati da versare a un conservatore, non sostituirlo.
- **Non promettere la FEA** senza la struttura organizzativa richiesta dal DPCM.

---

## Fonti principali

- Reg. UE 910/2014 (eIDAS): https://eur-lex.europa.eu/legal-content/IT/TXT/?uri=CELEX:32014R0910
- Reg. UE 2024/1183 (eIDAS 2): https://eur-lex.europa.eu/legal-content/IT/TXT/?uri=CELEX:32024R1183
- CAD, D.Lgs. 82/2005: https://www.normattiva.it/uri-res/N2Ls?urn:nir:stato:decreto.legislativo:2005-03-07;82
- DPCM 22/02/2013, regole tecniche firme: https://www.gazzettaufficiale.it/eli/id/2013/05/21/13A04284/sg
- AgID, Tipologie di firme e sigilli elettronici: https://www.agid.gov.it/sites/default/files/repository_files/tipologie_di_firme_e_sigilli_elettronici_v1_dicembre_2019.pdf
- AgID, linee guida firma con SPID (Det. 157/2020): https://www.agid.gov.it/it/agenzia/stampa-e-comunicazione/notizie/2020/03/26/spid-emanate-linee-guida-firmare-i-documenti-online
- Ministero dell'Interno, CieSign: https://www.cartaidentita.interno.gov.it/en/public-and-business-administration/electronic-signature-with-cie-ciesign/
- EU Trusted List Browser: https://eidas.ec.europa.eu/efda/tl-browser/
- ETSI EN 319 162-1 (ASiC): https://www.etsi.org/deliver/etsi_en/319100_319199/31916201/
- ETSI EN 319 102-1 (validazione): https://www.etsi.org/deliver/etsi_en/319100_319199/31910201/
- DSS, Commissione europea: https://ec.europa.eu/digital-building-blocks/DSS/webapp-demo/doc/dss-documentation.html
- Cloud Signature Consortium, API v2.2: https://cloudsignatureconsortium.org/resources/csc-api-v2-2/
- CSC API v2.0.0.2 (PDF): https://cloudsignatureconsortium.org/wp-content/uploads/2023/04/csc-api-v2.0.0.2.pdf
- CSC, white paper EUDI Wallet e QES remota: https://cloudsignatureconsortium.org/wp-content/uploads/2024/10/CSC-White-Paper-The-EU-digital-identity-wallet-a-new-tool-for-remote-signing-with-qualified-electronic-signatures.pdf
- InfoCert Developers: https://developers.infocert.digital/?p=3966
- InfoCert, documento TSA (validità marche): https://qtsp.infocert.it/pdf/ICERT_INDI_TDS.pdf
- Aruba PEC, QTSA disclosure statement: https://www.pec.it/repository/arubapec-qtsa-pds-it.pdf
- Namirial SWS: https://docs.namirial.app/products/sws/homepage
- Openapi (prezzi rivenditore InfoCert/Aruba): https://openapi.com/products/infocert-qualified-electronic-signature · https://openapi.com/products/aruba-time-stamps
- Bit4id su macOS (PKCS#11): https://suport-tcat.aoc.cat/hc/en-gb/articles/15086546156189-Bit4id-Manual-for-Mac-OS

> Nota di metodo: i testi normativi citati per articolo vanno riletti su EUR-Lex e Normattiva prima di usarli in documenti pubblici; alcune fonti secondarie numerano diversamente i commi dell'art. 5a di eIDAS 2. I prezzi sono di rivenditori o listini al pubblico e non valgono per contratti di integrazione.

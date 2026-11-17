#pragma once
// The app's texts in Italian and English (the other four languages of the Mac app come later:
// docs/STUDIO_WINDOWS_XIZ.md §11, phase 3). %ls/%llu placeholders are formatted with fmt().

#include <string>

#define XIZW_STRINGS(X) \
    X(AppName, L"Xipper XIZ", L"Xipper XIZ") \
    X(Open, L"Apri…", L"Open…") \
    X(ExtractAll, L"Estrai…", L"Extract…") \
    X(ExtractSel, L"Estrai selezione…", L"Extract selection…") \
    X(Verify, L"Verifica", L"Verify") \
    X(Cancel, L"Annulla", L"Cancel") \
    X(Close, L"Chiudi", L"Close") \
    X(MenuFile, L"&File", L"&File") \
    X(MenuOpen, L"&Apri…\tCtrl+O", L"&Open…\tCtrl+O") \
    X(MenuExtract, L"&Estrai…\tCtrl+E", L"&Extract…\tCtrl+E") \
    X(MenuExtractSel, L"Estrai &selezione…", L"Extract &selection…") \
    X(MenuVerify, L"&Verifica\tCtrl+T", L"&Verify\tCtrl+T") \
    X(MenuAssociate, L"Apri i file .xiz con Xipper XIZ", L"Open .xiz files with Xipper XIZ") \
    X(MenuUnassociate, L"Rimuovi l'associazione dei file .xiz", L"Remove the .xiz file association") \
    X(MenuExit, L"Es&ci", L"E&xit") \
    X(MenuHelp, L"&Aiuto", L"&Help") \
    X(MenuAbout, L"&Informazioni su Xipper XIZ", L"&About Xipper XIZ") \
    X(ColName, L"Nome", L"Name") \
    X(ColSize, L"Dimensione", L"Size") \
    X(ColModified, L"Modificato", L"Modified") \
    X(Empty, L"Trascina qui un archivio .xiz, oppure usa Apri…", L"Drop a .xiz archive here, or use Open…") \
    X(Summary, L"%llu elementi, %ls", L"%llu items, %ls") \
    X(Encrypted, L"cifrato", L"encrypted") \
    X(Working, L"Estrazione in corso…", L"Extracting…") \
    X(Verifying, L"Verifica in corso…", L"Verifying…") \
    X(OpenFilter, L"Archivi XIZ (*.xiz)", L"XIZ archives (*.xiz)") \
    X(AllFiles, L"Tutti i file", L"All files") \
    X(PwTitle, L"Archivio protetto", L"Protected archive") \
    X(PwLabel, L"«%ls» è protetto. Scrivi la password:", L"“%ls” is protected. Enter the password:") \
    X(PwShow, L"Mostra la password", L"Show password") \
    X(FactorLabel, L"File del secondo fattore (.xizfactor):", L"Second factor key file (.xizfactor):") \
    X(Browse, L"Sfoglia…", L"Browse…") \
    X(WrongPassword, L"Password sbagliata.", L"Wrong password.") \
    X(FactorNeeded, L"Questa password richiede anche il file del secondo fattore.", L"This password also needs its second factor key file.") \
    X(FactorWrong, L"Il file del fattore non corrisponde a questa password.", L"The factor key file does not match this password.") \
    X(FactorInvalid, L"Il file scelto non è un file di fattore XIZ (XIZ-FACTOR-1-…).", L"The chosen file is not an XIZ factor key file (XIZ-FACTOR-1-…).") \
    X(FactorFilter, L"Fattori XIZ (*.xizfactor)", L"XIZ factors (*.xizfactor)") \
    X(ExTitle, L"Estrai", L"Extract") \
    X(ExLabel, L"Estrai i file in questa cartella:", L"Extract the files to this folder:") \
    X(ExOpenAfter, L"Apri la cartella al termine", L"Show the folder when done") \
    X(ExButton, L"Estrai", L"Extract") \
    X(ConflictTitle, L"Il file esiste già", L"The file already exists") \
    X(ConflictText, L"«%ls» esiste già nella cartella di destinazione.", L"“%ls” already exists in the destination folder.") \
    X(ConflictReplace, L"Sostituisci", L"Replace") \
    X(ConflictSkip, L"Salta", L"Skip") \
    X(ConflictKeep, L"Mantieni entrambi", L"Keep both") \
    X(ConflictAll, L"Fai lo stesso per gli altri file", L"Do the same for the other files") \
    X(DoneTitle, L"Estrazione completata", L"Extraction complete") \
    X(DoneText, L"%llu file e %llu cartelle in %ls", L"%llu files and %llu folders in %ls") \
    X(DoneIssues, L"%llu elementi saltati o danneggiati", L"%llu items skipped or damaged") \
    X(DoneRenamed, L"%llu file rinominati perché il nome era già usato", L"%llu files renamed because the name was taken") \
    X(ShowDetails, L"Mostra i dettagli", L"Show details") \
    X(OpenFolder, L"Apri la cartella", L"Open the folder") \
    X(Cancelled, L"Operazione annullata.", L"Cancelled.") \
    X(FailTitle, L"Non è stato possibile completare l'operazione", L"The operation could not be completed") \
    X(OpenFail, L"Impossibile aprire «%ls»", L"Cannot open “%ls”") \
    X(NotXiz, L"Il file non è un archivio XIZ.", L"The file is not an XIZ archive.") \
    X(AppleCodec, L"L'archivio è compresso con LZRAVEN o LZMESH, codec che esistono solo su macOS 27. Chiedi a chi l'ha creato di rifarlo con la compressione standard (zstd) di Xipper.", L"The archive is compressed with LZRAVEN or LZMESH, codecs that exist only on macOS 27. Ask its author to make it again with Xipper's standard compression (zstd).") \
    X(Newer, L"L'archivio usa funzioni più nuove di questa versione. Aggiorna Xipper XIZ.", L"The archive uses features newer than this version. Update Xipper XIZ.") \
    X(Damaged, L"L'archivio è danneggiato.", L"The archive is damaged.") \
    X(VerifyOkTitle, L"L'archivio è integro", L"The archive is intact") \
    X(VerifyOkText, L"%llu file e %u blocchi controllati, nessun problema.", L"%llu files and %u blocks checked, no problems.") \
    X(VerifyBadTitle, L"L'archivio è danneggiato", L"The archive is damaged") \
    X(VerifyBadText, L"%u blocchi e %llu file danneggiati.", L"%u blocks and %llu files damaged.") \
    X(Associated, L"I file .xiz ora si aprono con Xipper XIZ, e il menu di Esplora file offre «Estrai qui» ed «Estrai in…».", L".xiz files now open with Xipper XIZ, and File Explorer offers “Extract here” and “Extract to…”.") \
    X(Unassociated, L"L'associazione dei file .xiz è stata rimossa.", L"The .xiz file association was removed.") \
    X(VerbExtractHere, L"Estrai qui", L"Extract here") \
    X(VerbExtractTo, L"Estrai in…", L"Extract to…") \
    X(FileType, L"Archivio XIZ", L"XIZ archive") \
    X(About, L"Xipper XIZ %ls\nApre ed estrae gli archivi XIZ di Xipper.\n\nlibxiz (MIT) con zstd, liblzma, Argon2, BearSSL, Monocypher, mlkem-native, mldsa-native, brunsli, Brotli, preflate e OpenZL.\nhttps://github.com/nicolorisitano82/xipper", L"Xipper XIZ %ls\nOpens and extracts Xipper's XIZ archives.\n\nlibxiz (MIT) with zstd, liblzma, Argon2, BearSSL, Monocypher, mlkem-native, mldsa-native, brunsli, Brotli, preflate and OpenZL.\nhttps://github.com/nicolorisitano82/xipper") \
    X(CrTitle, L"Credenziali", L"Credentials") \
    X(CrHeader, L"«%ls» si apre con:", L"“%ls” opens with:") \
    X(CrPassword, L"Password:", L"Password:") \
    X(CrAddPw, L"Aggiungi", L"Add") \
    X(CrAddKey, L"Aggiungi file di chiave…", L"Add key file…") \
    X(CrGiven, L"Credenziali fornite:", L"Credentials given:") \
    X(CrRemove, L"Rimuovi", L"Remove") \
    X(CrOpen, L"Apri", L"Open") \
    X(CrNotEnough, L"Le credenziali fornite non aprono l'archivio.", L"The credentials given do not open the archive.") \
    X(CrKeyInvalid, L"Il file scelto non contiene una chiave XIZ o age, né un fattore.", L"The chosen file holds no XIZ or age key and no factor.") \
    X(KeyFilter, L"File di chiave (*.key, *.xizfactor, *.txt)", L"Key files (*.key, *.xizfactor, *.txt)") \
    X(GivenPassword, L"Password %u", L"Password %u") \
    X(GivenKey, L"Chiave: %ls", L"Key: %ls") \
    X(GivenKeyPq, L"Chiave post-quantum: %ls", L"Post-quantum key: %ls") \
    X(GivenFactor, L"Fattore: %ls", L"Factor: %ls") \
    X(AccPassword, L"una password", L"a password") \
    X(AccPasswordLabel, L"la password «%ls»", L"the password “%ls”") \
    X(AccPasswordFactor, L"una password con il suo file di secondo fattore", L"a password with its second factor key file") \
    X(AccKey, L"la chiave «%ls»", L"the key “%ls”") \
    X(AccKeyPq, L"la chiave post-quantum «%ls»", L"the post-quantum key “%ls”") \
    X(AccThreshold, L"%d custodi su %d: %ls", L"%d custodians of %d: %ls") \
    X(AccOpened, L" ✓", L" ✓") \
    X(MenuUnlock, L"S&blocca altri gruppi…", L"&Unlock more groups…") \
    X(HiddenGroups, L"%u gruppi bloccati", L"%u locked groups") \
    X(ColGroup, L"Gruppo", L"Group") \
    X(GroupDefault, L"(principale)", L"(main)") \
    X(Signatures, L"Firme", L"Signatures") \
    X(MenuSignatures, L"&Firme…", L"Si&gnatures…") \
    X(MenuProperties, L"&Proprietà…\tAlt+Invio", L"&Properties…\tAlt+Enter") \
    X(MenuProof, L"Verifica una p&rova di inclusione…", L"Check an inclusion p&roof…") \
    X(SigTitle, L"Firme dei segmenti", L"Segment signatures") \
    X(SigColSegment, L"Segmento", L"Segment") \
    X(SigColSigner, L"Firmatario", L"Signer") \
    X(SigColDate, L"Data", L"Date") \
    X(SigColKind, L"Tipo", L"Kind") \
    X(SigColState, L"Stato", L"State") \
    X(SigColFingerprint, L"Impronta", L"Fingerprint") \
    X(SigUnsigned, L"non firmato", L"unsigned") \
    X(SigValid, L"valida", L"valid") \
    X(SigInvalid, L"NON VALIDA", L"INVALID") \
    X(SigBroken, L"valida, catena INTERROTTA", L"valid, chain BROKEN") \
    X(SigUnknown, L"algoritmo sconosciuto, non verificata", L"unknown algorithm, not verified") \
    X(SigTimestamp, L" + marca temporale (non verificata)", L" + time-stamp (not verified)") \
    X(SigNote, L"Le firme con certificato sono verificate con la chiave del certificato: se l'emittente è affidabile lo decidi tu, dall'impronta SHA-256. Le marche temporali sono mostrate, non verificate.", L"Certificate signatures are checked with the certificate's key: whether the issuer is trusted is up to you, from its SHA-256 fingerprint. Time-stamps are shown, not verified.") \
    X(NoSignatures, L"L'archivio non ha firme.", L"The archive has no signatures.") \
    X(AlgEd25519, L"Ed25519", L"Ed25519") \
    X(AlgP256, L"ECDSA P-256, certificato", L"ECDSA P-256, certificate") \
    X(AlgRsa, L"RSA, certificato", L"RSA, certificate") \
    X(AlgHybrid, L"Ed25519 + ML-DSA-65 (post-quantum)", L"Ed25519 + ML-DSA-65 (post-quantum)") \
    X(AlgEnclave, L"Secure Enclave P-256 + ML-DSA-65", L"Secure Enclave P-256 + ML-DSA-65") \
    X(PropTitle, L"Proprietà", L"Properties") \
    X(PropFormat, L"Formato: XIZ %u.%u", L"Format: XIZ %u.%u") \
    X(PropId, L"Identificativo: %ls", L"Archive id: %ls") \
    X(PropEncrypted, L"Cifrato: %ls", L"Encrypted: %ls") \
    X(Yes, L"sì", L"yes") \
    X(No, L"no", L"no") \
    X(PropSegments, L"Segmenti: %u (%u firmati)", L"Segments: %u (%u signed)") \
    X(PropEntries, L"Elementi: %u (%llu visibili)", L"Items: %u (%llu visible)") \
    X(PropBytes, L"Dimensione dei file: %ls", L"Size of the files: %ls") \
    X(PropFile, L"Dimensione dell'archivio: %ls", L"Size of the archive: %ls") \
    X(PropGroups, L"Gruppi di accesso:", L"Access groups:") \
    X(PropLocked, L"bloccato", L"locked") \
    X(PropAccess, L"Si apre con:", L"Opens with:") \
    X(PropRecovery, L"Recovery record: ripara fino a %u blocchi da %u KiB", L"Recovery record: repairs up to %u blocks of %u KiB") \
    X(PropNoRecovery, L"Recovery record: assente", L"Recovery record: none") \
    X(PropWindows, L"Leggibile su Windows e Linux: %ls", L"Readable on Windows and Linux: %ls") \
    X(PropAppleNo, L"no (codec Apple LZRAVEN o LZMESH)", L"no (Apple's LZRAVEN or LZMESH codec)") \
    X(RecOk, L"Recovery record: nessun danno.", L"Recovery record: no damage.") \
    X(RecDamaged, L"Recovery record: %u blocchi danneggiati, %ls.", L"Recovery record: %u damaged blocks, %ls.") \
    X(RecRepairable, L"riparabili", L"repairable") \
    X(RecNotRepairable, L"troppi per ripararli", L"too many to repair") \
    X(RepairCopy, L"Ripara una copia", L"Repair a copy") \
    X(Repairing, L"Riparazione in corso…", L"Repairing…") \
    X(RepairedTitle, L"Copia riparata", L"Copy repaired") \
    X(RepairedText, L"La copia riparata è «%ls». L'originale non è stato toccato.", L"The repaired copy is “%ls”. The original was not touched.") \
    X(RepairFail, L"Non è stato possibile riparare l'archivio.", L"The archive could not be repaired.") \
    X(RepairedSuffix, L" (riparato)", L" (repaired)") \
    X(OpenCopy, L"Apri la copia", L"Open the copy") \
    X(DamagedRepairable, L"L'archivio ha un recovery record: puoi ripararne una copia.", L"The archive has a recovery record: you can repair a copy.") \
    X(ProofPickJson, L"Scegli la prova (.json)", L"Choose the proof (.json)") \
    X(ProofPickFile, L"Scegli il file da controllare", L"Choose the file to check") \
    X(ProofFilter, L"Prove di inclusione (*.json)", L"Inclusion proofs (*.json)") \
    X(ProofOkTitle, L"La prova è valida", L"The proof is valid") \
    X(ProofOkText, L"«%ls» (%llu byte) era nell'archivio, segmento %u.", L"“%ls” (%llu bytes) was in the archive, segment %u.") \
    X(ProofSigned, L"Segmento firmato da %ls il %ls (%ls).", L"Segment signed by %ls on %ls (%ls).") \
    X(ProofUnsigned, L"Il segmento non è firmato: la prova lega il file all'albero, non a una persona.", L"The segment is not signed: the proof ties the file to the tree, not to a person.") \
    X(ProofBadTitle, L"La prova non corrisponde", L"The proof does not match") \
    X(ColType, L"Tipo", L"Type") \
    X(Back, L"Indietro (Alt+Freccia sinistra)", L"Back (Alt+Left arrow)") \
    X(Up, L"Cartella superiore (Alt+Freccia su)", L"Up one level (Alt+Up arrow)") \
    X(FolderItems, L"%llu elementi in questa cartella", L"%llu items in this folder") \
    X(Preparing, L"Preparazione dei file…", L"Preparing the files…") \
    X(NewArchive, L"Nuovo archivio…", L"New archive…") \
    X(MenuNew, L"&Nuovo archivio…\tCtrl+N", L"&New archive…\tCtrl+N") \
    X(AddBtn, L"Aggiungi…", L"Add…") \
    X(MenuAddFiles, L"Aggiungi &file…", L"Add &files…") \
    X(MenuAddFolder, L"Aggiungi c&artella…", L"Add a fol&der…") \
    X(DeleteBtn, L"Elimina", L"Delete") \
    X(MenuDelete, L"E&limina\tCanc", L"&Delete\tDel") \
    X(NewTitle, L"Nuovo archivio XIZ", L"New XIZ archive") \
    X(NewArchiveLabel, L"Archivio:", L"Archive:") \
    X(NewContents, L"Contenuto:", L"Contents:") \
    X(NewAddFiles, L"Aggiungi file…", L"Add files…") \
    X(NewAddFolder, L"Aggiungi cartella…", L"Add folder…") \
    X(NewRemove, L"Rimuovi", L"Remove") \
    X(NewLevel, L"Compressione:", L"Compression:") \
    X(LevelFast, L"Veloce", L"Fast") \
    X(LevelNormal, L"Normale", L"Normal") \
    X(LevelMax, L"Massima", L"Maximum") \
    X(NewUsePw, L"Proteggi con una password", L"Protect with a password") \
    X(NewPw, L"Password:", L"Password:") \
    X(NewPw2, L"Ripeti la password:", L"Repeat the password:") \
    X(StrengthLabel, L"Robustezza: %ls", L"Strength: %ls") \
    X(StrengthWeak, L"Debole", L"Weak") \
    X(StrengthFair, L"Discreta", L"Fair") \
    X(StrengthGood, L"Buona", L"Good") \
    X(StrengthExcellent, L"Ottima", L"Excellent") \
    X(NewStrong, L"Protezione più lenta da forzare", L"Slower to crack") \
    X(NewRecovery, L"Aggiungi un recovery record (ripara piccoli danni)", L"Add a recovery record (repairs small damage)") \
    X(NewCreate, L"Crea", L"Create") \
    X(NewNoSources, L"Aggiungi almeno un file o una cartella.", L"Add at least one file or folder.") \
    X(NewPwMismatch, L"Le password non coincidono.", L"The passwords don't match.") \
    X(NewPwEmpty, L"Scrivi una password.", L"Enter a password.") \
    X(WeakTitle, L"Password debole", L"Weak password") \
    X(WeakText, L"Si può indovinare in poco tempo: chi ha l'archivio potrebbe aprirlo. Usarla lo stesso?", L"It can be guessed quickly: whoever has the archive could open it. Use it anyway?") \
    X(UseAnyway, L"Usala lo stesso", L"Use it anyway") \
    X(NewExists, L"«%ls» esiste già. Sostituirlo?", L"“%ls” already exists. Replace it?") \
    X(Creating, L"Compressione in corso…", L"Compressing…") \
    X(Updating, L"Aggiornamento dell'archivio…", L"Updating the archive…") \
    X(CreatedTitle, L"Archivio creato", L"Archive created") \
    X(CreatedText, L"%ls\n%llu file, %ls → %ls", L"%ls\n%llu files, %ls → %ls") \
    X(ShowInFolder, L"Mostra nella cartella", L"Show in folder") \
    X(DeleteConfirm, L"Eliminare %llu elementi da «%ls»?", L"Delete %llu items from “%ls”?") \
    X(DeleteNote, L"I dati restano nel file finché l'archivio non viene ricreato: chi conosce la password potrebbe ancora recuperarli.", L"The data stays in the file until the archive is made again: whoever knows the password could still recover it.") \
    X(VerbAddToXiz, L"Aggiungi a un archivio XIZ…", L"Add to an XIZ archive…") \
    X(CantModify, L"Per modificarlo servono le chiavi di tutti i gruppi di accesso (File > Sblocca altri gruppi); gli archivi firmati, cancellabili o forensi si modificano solo con Xipper sul Mac.", L"Changing it needs the keys of all its access groups (File > Unlock more groups); signed, erasable or forensic archives can be changed only with Xipper on a Mac.") \
    X(DefaultArchiveName, L"Archivio", L"Archive") \
    X(AccessBtn, L"Destinatari e custodi…", L"Recipients and custodians…") \
    X(AccessInfo, L"%u modi di accesso: la password qui sopra non viene usata.", L"%u ways in: the password above is not used.") \
    X(AcTitle, L"Chi può aprire l'archivio", L"Who can open the archive") \
    X(AcColWho, L"Chi", L"Who") \
    X(AcColFolders, L"Cartelle", L"Folders") \
    X(AcAddPw, L"Password…", L"Password…") \
    X(AcAddKey, L"Chiave pubblica…", L"Public key…") \
    X(AcAddCust, L"Custodi…", L"Custodians…") \
    X(AcHint, L"Le cartelle sono quelle dell'archivio, per esempio «documenti/2026». Chi non ha cartelle elencate apre tutto.", L"Folders are the archive's, e.g. “documents/2026”. Whoever has no folders listed opens everything.") \
    X(AcKindPw, L"Password", L"Password") \
    X(AcKindPwFactor, L"Password + fattore", L"Password + factor") \
    X(AcKindKey, L"Chiave", L"Key") \
    X(AcKindKeyPq, L"Chiave post-quantum", L"Post-quantum key") \
    X(AcKindCust, L"%d custodi su %d", L"%d of %d custodians") \
    X(AcAll, L"tutto", L"everything") \
    X(AcLabel, L"Etichetta (visibile a tutti):", L"Label (visible to anyone):") \
    X(AcFactor, L"Con un secondo fattore (un file .xizfactor da tenere a parte)", L"With a second factor (a .xizfactor file to keep apart)") \
    X(AcFolders, L"Solo queste cartelle (una per riga; vuoto: tutto):", L"Only these folders (one per line; empty: everything):") \
    X(AcKeyLabel, L"Chiave pubblica (xizpk1…, xizpq1…, age1…):", L"Public key (xizpk1…, xizpq1…, age1…):") \
    X(AcFromFile, L"Da file…", L"From file…") \
    X(AcKeyInvalid, L"Non è una chiave pubblica XIZ o age.", L"Not an XIZ or age public key.") \
    X(AcNeed, L"Ne servono", L"Needed:") \
    X(AcOfN, L"su %u", L"of %u") \
    X(AcCustKey, L"Chiave…", L"Key…") \
    X(AcCustTooFew, L"Servono almeno 2 custodi, e non più di quanti ce ne sono.", L"At least 2 custodians are needed, and no more than there are.") \
    X(AcNoMain, L"Le cartelle non elencate non le aprirebbe nessuno: aggiungi un accesso senza cartelle.", L"Nobody would open the folders not listed: add a way in without folders.") \
    X(AcFactorSave, L"Salva il file del secondo fattore", L"Save the second factor file") \
    X(AcFactorFile, L"Tieni «%ls» separato dall'archivio: senza, la password non basta.", L"Keep “%ls” apart from the archive: without it the password is not enough.") \
    X(AcNone, L"Aggiungi almeno una password, una chiave o un gruppo di custodi.", L"Add at least a password, a key or a custodian group.") \
    X(MenuKeys, L"Le mie c&hiavi…", L"My &keys…") \
    X(KeysTitle, L"Le mie chiavi", L"My keys") \
    X(KeysNote, L"Servono ad aprire gli archivi indirizzati a te: dai agli altri la chiave pubblica. Le chiavi segrete restano in questo PC, protette da Windows per il tuo utente.", L"They open archives sent to you: give others the public key. The secret keys stay on this PC, protected by Windows for your user.") \
    X(KeysNew, L"Nuova…", L"New…") \
    X(KeysCopy, L"Copia la chiave pubblica", L"Copy the public key") \
    X(KeysImport, L"Importa…", L"Import…") \
    X(KeysExport, L"Esporta…", L"Export…") \
    X(KeysColPublic, L"Chiave pubblica", L"Public key") \
    X(KeysTypePq, L"post-quantum", L"post-quantum") \
    X(KeysNameLabel, L"Nome della chiave:", L"Key name:") \
    X(KeysPq, L"Post-quantum (consigliata)", L"Post-quantum (recommended)") \
    X(KeysCopied, L"Chiave pubblica copiata negli appunti.", L"Public key copied to the clipboard.") \
    X(KeysExportWarn, L"Chi ha questo file apre gli archivi indirizzati a te. Esportarlo?", L"Whoever has this file opens the archives sent to you. Export it?") \
    X(KeysDeleteWarn, L"Eliminare «%ls»? Gli archivi indirizzati a questa chiave non si apriranno più qui.", L"Delete “%ls”? Archives sent to this key will no longer open here.") \
    X(GivenStored, L"Chiave salvata: %ls", L"Stored key: %ls") \
    X(SecretFilter, L"Chiavi segrete (*.key)", L"Secret keys (*.key)") \
    X(PublicFilter, L"Chiavi pubbliche (*.pub, *.txt)", L"Public keys (*.pub, *.txt)") \
    X(Usage, L"Uso: XipperXIZ [archivio.xiz]\n  /x archivio [/d CARTELLA]   estrai (qui, in una cartella col nome dell'archivio)\n  /xto archivio               chiedi dove estrarre\n  /t archivio                 verifica (e recovery record)\n  /repair archivio            ripara una copia col recovery record\n  /info archivio              proprietà e firme\n  /passenv VAR, /identity FILE, /factor FILE   credenziali (ripetibili)\n  /new archivio /src FILE [/level 3|9|19] [/passenv VAR] [/recovery]   crea\n  /append archivio /src FILE [/folder CARTELLA], /remove archivio /entry PERCORSO\n  /register, /unregister      associa o no i file .xiz", L"Usage: XipperXIZ [archive.xiz]\n  /x archive [/d FOLDER]   extract (here, into a folder named after the archive)\n  /xto archive             ask where to extract\n  /t archive               verify (and the recovery record)\n  /repair archive          repair a copy with the recovery record\n  /info archive            properties and signatures\n  /passenv VAR, /identity FILE, /factor FILE   credentials (repeatable)\n  /new archive /src FILE [/level 3|9|19] [/passenv VAR] [/recovery]   create\n  /append archive /src FILE [/folder FOLDER], /remove archive /entry PATH\n  /register, /unregister   associate .xiz files, or not")

enum class S {
#define XIZW_ENUM(id, it, en) id,
    XIZW_STRINGS(XIZW_ENUM)
#undef XIZW_ENUM
    Count
};

const wchar_t *T(S id);
// The language in use: "it", "en", "de", "es", "fr", "ja" or "zh-Hans" (XIZW_LANG overrides).
const char *language();
std::wstring fmt(S id, ...);
std::wstring vfmt(const wchar_t *f, ...);

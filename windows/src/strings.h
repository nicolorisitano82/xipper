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
    X(MenuExit, L"E&sci", L"E&xit") \
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
    X(Usage, L"Uso: XipperXIZ [archivio.xiz]\n  /x archivio [/d CARTELLA]   estrai (qui, in una cartella col nome dell'archivio)\n  /xto archivio               chiedi dove estrarre\n  /t archivio                 verifica\n  /register, /unregister      associa o no i file .xiz", L"Usage: XipperXIZ [archive.xiz]\n  /x archive [/d FOLDER]   extract (here, into a folder named after the archive)\n  /xto archive             ask where to extract\n  /t archive               verify\n  /register, /unregister   associate .xiz files, or not")

enum class S {
#define XIZW_ENUM(id, it, en) id,
    XIZW_STRINGS(XIZW_ENUM)
#undef XIZW_ENUM
    Count
};

const wchar_t *T(S id);
std::wstring fmt(S id, ...);
std::wstring vfmt(const wchar_t *f, ...);

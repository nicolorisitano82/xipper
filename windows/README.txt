Xipper XIZ for Windows
======================

Opens, verifies, extracts and creates XIZ archives, readable by Xipper on the Mac and by xiz everywhere.

- Double-click XipperXIZ.exe, then Open… or drop a .xiz file on the window.
- File > "Open .xiz files with Xipper XIZ": .xiz files open with a double-click, and File Explorer
  offers "Extract here" and "Extract to…" (on Windows 11 under "Show more options"). No administrator
  rights needed; File > "Remove the .xiz file association" undoes it.
- New archive (Ctrl+N), or drop files and folders on the empty window, or right-click files or
  folders in File Explorer > "Add to an XIZ archive…" (after the association). Fast / Normal /
  Maximum compression, a password with a strength meter (the same estimate as Xipper on the Mac),
  "Slower to crack" (with 8 GB of RAM or more), a recovery record. Encrypted archives are XIZ 1.14
  with key commitment.
- "Recipients and custodians…" in the new archive window: several passwords (also with a second
  factor), public keys (xizpk1…, xizpq1…, age1…), custodian groups (k of n); each opens everything
  or only some folders. The archives are XIZ 1.3 like those of Xipper on the Mac.
- File > "My keys": keys to receive archives (post-quantum by default). Give senders the public key;
  the secret one stays on the PC, protected by Windows (DPAPI), and opens archives sent to you.
- In an open archive: Add… (or drop files on the window) puts files into the open folder; Delete
  removes them. Deleted data stays in the file until the archive is made again. Archives with
  access groups need the keys of all groups; signed, erasable or forensic ones change only with Xipper.
- Protected archives: password and, when asked, the second factor key file (.xizfactor). For
  archives with recipients or custodians the window lists how they open: add passwords and key
  files (XIZ-SECRET-KEY-…, AGE-SECRET-KEY-…). With a locked group, File > "Unlock more groups".
- File > Signatures: who signed each segment, and whether the signature holds. File > Properties
  (Alt+Enter).
- Verify also checks the recovery record; a damaged but repairable archive gets "Repair a copy",
  which writes "name (repaired).xiz" and leaves the original alone.
- Browse the archive as in File Explorer: folders on the left, contents on the right, Back and Up
  (Alt+Left, Alt+Up, Backspace), sortable columns.
- Double-click a file in the list to open it with its program; drag the selection to File Explorer
  to extract it there. Both go through a private temporary folder, removed on exit.
- Files extracted from an archive downloaded from the Internet keep its Mark of the Web.
- Languages: English, Italian, German, Spanish, French, Japanese, Simplified Chinese (Windows' language).

Command line: XipperXIZ /? (also xiz.exe for scripts: xiz --help).

First start: the program has no commercial signature, so Windows may say "Windows protected your
PC". Check the SHA-256 published next to the zip, then "More info" > "Run anyway".

Limits: archives compressed with LZRAVEN or LZMESH (Apple codecs, macOS 27 only) do not open.
RFC 3161 time-stamps are shown, not verified; certificate chains are not validated (compare the
SHA-256 fingerprint).

MIT License. Source: https://github.com/nicolorisitano82/xipper (windows/, libxiz/).
The licenses of the bundled libraries are in the licenses folder.

Xipper XIZ for Windows
======================

Opens, verifies and extracts the XIZ archives made with Xipper (macOS). It does not create archives (yet).

- Double-click XipperXIZ.exe, then Open… or drop a .xiz file on the window.
- File > "Open .xiz files with Xipper XIZ": .xiz files open with a double-click, and File Explorer
  offers "Extract here" and "Extract to…" (on Windows 11 under "Show more options"). No administrator
  rights needed; File > "Remove the .xiz file association" undoes it.
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

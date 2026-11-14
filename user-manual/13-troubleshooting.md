# 13. Limits, troubleshooting and help

## Known limits

- **RAR** is read-only. Encrypted RAR 4 archives and encrypted split RAR5 archives are not supported.
- **ISO, DMG and MPEG-G** cannot be opened yet.
- **CRAM** files are not browsed like archives: convert them to BAM.
- **Encrypted Apple Archives** need a password of at least 20 characters (a macOS limit).
- **Mounted archives** are local WebDAV volumes: opening a very large file the first time reads all of it.
- **Apple codecs** (LZRAVEN, LZMESH) work only on macOS 27, to write and to read.
- **Erasing a file permanently** works only in XIZ archives created with erasable files, and does not reach copies made before the erasure.
- **Signatures** prove who signed and that nothing changed since. They do not stop someone from removing the latest versions (the history stays valid but shorter): write down the archive's SHA-256 or the number of versions when it matters.

## Common problems

| Problem | What to do |
|---|---|
| macOS says Xipper "cannot be opened" | First launch: **System Settings › Privacy & Security › Open Anyway** ([chapter 1](01-getting-started.md#first-launch)) |
| The Finder menu doesn't appear | Enable **Xipper in the Finder** in **System Settings › General › Login Items & Extensions › Finder Extensions**, then relaunch the Finder (⌥-right-click its Dock icon › Relaunch) |
| `xipper: command not found` | Link the command again from **Help › Welcome to Xipper** ([chapter 10](10-command-line.md#installing-the-command)) |
| Names in an old ZIP look garbled | **Actions › Name Encoding**: try cp437 (DOS), cp850, windows1252, Shift-JIS, GBK… |
| "A part of the archive is missing" | Click **Locate…** and choose the missing `.z01`, `.002`, … |
| An archive fails verification | If it has recovery data, click **Repair**. A ZIP can often be rebuilt with **Repair** anyway ([chapter 5](05-verify-repair-checksums.md)) |
| Extracted apps or scripts won't open | They come from the Internet and keep the quarantine on purpose. Check where they come from, then open them with right-click › Open |
| Files were skipped during extraction | The list at the end gives the reason: a path outside the destination, a link, a zip bomb, a deceptive name |
| An XIZ archive "needs a newer Xipper" | It uses a feature of a later format version: update Xipper ([compatibility](06-xiz.md#compatibility)) |
| A signature shows "Signed with an algorithm this version does not know" | Made by a newer Xipper: update to check it |
| "Change Format" was interrupted | Reopen the original: the banner offers **Resume** ([chapter 4](04-editing-mounting-converting.md#converting-with-little-free-space)) |
| Not enough space to convert | Use **Convert with Little Free Space** (ZIP or 7z to XIZ) |

## Reading XIZ without Xipper

`xiz` is a free, independent reader written in C (libxiz, MIT license), for Linux, Windows and macOS. Whoever receives an XIZ archive can open and check it without Xipper and without a Mac.

What it reads:
- every XIZ feature: encryption, access groups, identities, custodians;
- recompressed photos, documents, tables and AI models;
- signatures, the post-quantum ones included;
- proofs of inclusion and forensic archives.

```bash
xiz list archive.xiz
xiz test archive.xiz
xiz extract -d out archive.xiz
xiz history archive.xiz
xiz verify-proof proof.json file
xiz cat archive.xiz path/in/archive > file
```

**Ready-made builds** for Linux (x86_64, arm64), Windows (x86_64) and macOS are published with [Xipper Forensic 1.0](https://github.com/nicolorisitano82/xipper/releases/tag/forensic-v1.0.0). They predate XIZ 1.11 and 1.12, so they do not read tables, AI models or post-quantum signatures.

**An up-to-date `xiz`** can be built from the repository: the source is in `libxiz/`, and the format specification is in `docs/XIZ_SPEC.md`.

```bash
git clone https://github.com/nicolorisitano82/xipper && cd xipper
cmake -S libxiz -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target xiz_cli   # this system
scripts/build-xiz-portable.sh                                                                 # Linux and Windows too (needs zig)
```

## Reporting a problem

Open an issue at <https://github.com/nicolorisitano82/xipper/issues> with:
- your macOS version and Xipper version (**Xipper › About Xipper**);
- what you did, what you expected and what happened;
- for the command line, the exact command and its output.

Please don't attach archives with personal or confidential content.

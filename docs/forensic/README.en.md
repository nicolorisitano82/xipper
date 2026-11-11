# Xipper Forensic 0.9 — preview

*[Italiano](LEGGIMI.md) · English*

Xipper Forensic acquires, verifies and keeps custody of digital evidence in **forensic XIZ archives**: each archive carries the hash of every block, the hash of the source, the case and evidence-item records and the chain of custody, all signed. It belongs to the Xipper family but is a separate app. For Apple Silicon Macs with **macOS 26 or later**. Free, MIT license.

**Preview:** this version acquires **files and folders**, **image files** (.dd, .img, .raw…) and a **Mac in Share Disk mode** connected read-only. Direct acquisition of disks (`/dev/rdiskN`, with mounts blocked) comes with 1.0. Before using it on a real case, try it on test data and compare the hashes with another tool.

## Installation
1. Open the `.dmg` and drag **Xipper Forensic** to **Applications**.
2. **First launch.** The app is signed with its own certificate, not an Apple Developer ID, so macOS blocks it the first time: open the app, choose **Done**, then press **Open Anyway** in **System Settings › Privacy & Security**. Or, from Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Xipper Forensic.app"
   ```

3. The SHA-256 of the DMG is in the `.sha256` file next to it.

## Getting started
1. **Settings** (⌘,): your operator name and a **signing key** (created there, kept in the Keychain). Everything you do is signed with this key: give the public key, shown below it, to whoever will check the signatures.
2. Optional: a **time-stamp authority** (RFC 3161). Without one the app works **offline**, never goes on the network, and the report says so.
3. **New Case…**: case number, proceeding, authority, location. A case is a `.xfcase` folder.

## Acquiring an evidence item
**New Evidence Item…** opens a six-step procedure, always in the same order:
1. **Evidence item:** number (R01, R02… proposed), description, model, serial number, seals found.
2. **Source:** files and folders, an image file, or a Mac via Share Disk. For a Mac: start it in recoveryOS, choose Utilities › Share Disk, connect the two Macs with a cable or on the same network and enter the address it shows; the app mounts the share read-only and refuses a writable mount.
3. **Options:** MD5 and SHA-1 for compatibility (SHA-256 always), compression, extended attributes, password encryption.
4. **Checks:** ✔ passed, ⚠ warning (you can go on, it stays in the log), ⛔ blocked. To start, type your name: the checks and your confirmation go into the case log.
5. **Acquisition:** progress, pause, interruption with a reason. The Mac does not sleep.
6. **Three-state outcome:** complete · complete with warnings (unreadable items, listed in the signed inventory) · failed.

The evidence folder then holds the archive `Rnn.xiz`, the report `Rnn.report.json` and the printable `Rnn.report.pdf`, both signed (`.sig`).

**Write the archive's SHA-256 into your written record**: it is the outside reference that makes any later change evident.

## Custody and verification
- **Hand-over…** appends a signed custody segment to the archive (from, to, reason, state of the seals): the content does not change and earlier signatures stay valid.
- **Verify Case** checks the signed chain of the log, the case record and the hash of every archive and report.
- **Verify an Archive…** opens any forensic `.xiz`, with or without its case: structure, hash of every block, signatures, time-stamps, source hash, and the SHA-256 from your record if you enter it. The password is not needed for these checks.

## For whoever receives the evidence
An archive can be verified without the app:
- with the bundled command line: `"/Applications/Xipper Forensic.app/Contents/Helpers/xipper-forensic" verify R01.xiz --expect-sha256 <hash from the record>`;
- with `xiz forensic R01.xiz` from **libxiz**, an independent C implementation of the format that also builds on Linux and Windows (the `libxiz` folder of the repository).

The format is documented in `docs/XIZ_SPEC.md` §20.

## Limits of this preview
- No direct disk acquisition: it comes with 1.0, together with the helper that opens disks read-only and blocks mounting.
- The technical details of the checks are in English in the Italian report too.
- XIZ makes tampering evident, not impossible: removing the last custody segments leaves a valid archive. That is why the record should hold the archive's SHA-256 and the number of hand-overs.
- Apple silicon only, both the Mac that acquires and the source Mac in Share Disk. Intel Macs are not supported.

Issues: https://github.com/nicolorisitano82/xipper/issues

# Xipper Forensic 1.0

*[Italiano](LEGGIMI.md) · English*

Xipper Forensic acquires, verifies and keeps digital evidence in **forensic XIZ archives**: each archive carries the hash of every block, the source hash, the case and evidence records, the map of unreadable sectors and the chain of custody, all signed. Part of the Xipper family, as a separate app. For **Apple silicon** Macs with **macOS 26 or later** only. Free, MIT license.

Before using it on a real case, read the **validation document** (`VALIDAZIONE.md`, in Italian): what was tested, how, with which results, and what was not. You can repeat the tests on your Mac with `scripts/forensic-validation.sh` from the repository.

## Installing
1. Open the `.dmg` and drag **Xipper Forensic** to **Applications**.
2. **First launch.** The app is signed with its own certificate, not an Apple Developer ID, so macOS blocks it the first time: open it, choose **Done**, then press **Open Anyway** in **System Settings › Privacy & Security**. Or, in Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Xipper Forensic.app"
   ```

3. The DMG's SHA-256 is in the `.sha256` file next to it.

## First steps
1. **Settings** (⌘,):
   - your examiner name;
   - how you sign: a **Xipper key** (created there, kept in the Keychain) or a **certificate** from the Keychain or a smart card (ECDSA P-256 or RSA), which ties the signature to your identity;
   - optional: an **RFC 3161 time-stamp authority**, also with an account, and checking time-stamps against the **EU trusted list** (Italy: AgID) to tell whether they are qualified. With no authority the app works **offline** and the report says so;
   - **Disks**: install the **disk helper** (below) to acquire real disks.
2. **New Case…**: case number, proceeding, authority, location. A case is a `.xfcase` folder.

## The disk helper
Disks belong to the system: reading them needs a small helper that runs as root and does one thing, opening a disk **read-only** and handing it to the app. It never writes. Two approvals, both yours:
1. **Settings › Disks › Install…**, then allow the helper in **System Settings › General › Login Items & Extensions**;
2. **internal** disks only: **Privacy & Security › Full Disk Access**, add `xipper-forensic-helper`.

Disk images you attached yourself are read without the helper.

## Acquiring an evidence item
**New Evidence…** opens a six-step procedure, always in the same order:
1. **Evidence item:** number (R01, R02…), description, model, serial number, seals found.
2. **Source:**
   - **Disk**: the whole disk or one partition, read sector by sector. The startup disk and the disk holding the case are excluded; an internal disk asks for its serial number typed by hand. Use a hardware write blocker when you can;
   - **Files and folders**: logical acquisition with a signed inventory of everything found, including what cannot be read;
   - **Image file**: a raw image (.dd, .img, .001…) or an **E01**, imported with its MD5 and SHA-1 checked;
   - **Share Disk**: a Mac started in recoveryOS with Utilities › Share Disk, mounted read-only.
3. **Options:** MD5 and SHA-1 for compatibility (SHA-256 always), **read errors** (Fast, Standard, Exhaustive), compression, password encryption.
4. **Checks:** ✔ passed, ⚠ warning (kept in the log), ⛔ blocked. Type your name to start.
5. **Acquisition:** progress, a **disk map** with unreadable sectors, pause, interruption with a reason. macOS cannot mount the disk while it is read; the Mac does not sleep.
6. **Three-state outcome:** complete · complete with warnings (unreadable sectors or items, listed and signed) · failed.

The evidence folder then holds the archive `Rnn.xiz` and the reports `Rnn.report.json` and `Rnn.report.pdf`, signed (`.sig`).

**Write the archive's SHA-256 into your written record**: it is the outside reference that makes any later change evident.

## Custody, delivery, export
- **Hand-over…** appends a signed custody segment: the content does not change and earlier signatures stay valid.
- **Deliver a Copy…** prepares a copy for someone, in its own folder with a **signed receipt**; the original records the hand-over. Formats: a new XIZ for the recipient's public key or a password, the raw image with its hashes, E01, or a few files of a logical acquisition, each with its proof of belonging to the signed archive.
- **Export** an image as raw or **E01** (1.5 GB segments with the case fields, MD5 and SHA-1; checked with `ewfverify` and The Sleuth Kit).
- **Verify Case** and **Verify an Archive…** check the log, signatures, certificates, time-stamps, source hash and the SHA-256 from your record.

## For whoever receives the evidence
Anyone can verify an archive without the app and without a Mac, with **xiz** (libxiz, an independent implementation of the format in C), released with this version for **Linux, Windows and macOS**:

```bash
xiz forensic R01.xiz
xiz cat R01.xiz image.dd | sha256sum
```

The format is documented in `docs/XIZ_SPEC.md` §20 of the repository.

## Limits
- XIZ makes tampering evident, it does not prevent it: removing the last custody segments leaves a valid archive. So the record should hold the archive's SHA-256 and the number of hand-overs.
- Unreadable sectors, smart cards and qualified authorities were tested as the validation document describes: read it before a real case.
- The EU trusted list is fetched over https; its XML signature is not verified by this version (the report gives its SHA-256).
- Technical details of the checks are in English in the Italian report too.
- Apple silicon only, both the Mac that acquires and a source Mac in Share Disk. Intel Macs are not supported.

Issues: https://github.com/nicolorisitano82/xipper/issues

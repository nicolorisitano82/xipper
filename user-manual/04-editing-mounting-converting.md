# 4. Editing, mounting and converting

## Editing an archive in place

You don't need to extract an archive to change it. In the browser:

| To | Do |
|---|---|
| Rename a file or folder | Right-click › **Rename…** |
| Remove items | **Delete** |
| Add files | **Add Files…**, or drop files on the table |

Xipper rewrites only what it must:

| Format | What happens |
|---|---|
| **ZIP** | Entries you don't touch are copied as they are, without recompressing them |
| **7z** | Only the blocks you touch are compressed again. In a non-solid archive that is just the new files; in a solid one, the blocks that lose or replace a file |
| **XIZ** | The change is appended to the end of the archive as a new segment. Nothing already written is rewritten, every earlier state stays available as a version, and the change can be signed |
| **Other formats** | The archive is rebuilt |

The new archive is always written under a temporary name, made durable on disk and only then given the original's name. A crash or a power cut never leaves you without an archive.

From the command line:

```bash
xipper edit archive.zip --delete old/notes.txt --rename draft.md:final.md --add ~/new.pdf:docs/new.pdf
```

**Compacting XIZ:** deleted data stays in an XIZ archive, as earlier versions, until you compact it. Use `xipper edit --compact archive.xiz`.

## Mounting an archive as a volume

**Mount** (toolbar), or **Finder › Xipper › Mount as a Volume**, makes the archive appear in `/Volumes`.
- You can open its files and edit them in the Finder or in any app.
- When you **Eject** it, Xipper asks whether to save the changes into the archive.
- **Read-only:** older XIZ versions and archives you only want to read can be mounted read-only.

The mounted archive is a local WebDAV volume, served only to your Mac. The first time you open a very large file, macOS reads all of it.

From the command line, `xipper mount archive.zip` mounts until you eject it or press Ctrl-C. Options:
- `--read-only`;
- `--discard`, which drops the changes;
- `--at DIR`, which mounts somewhere other than `/Volumes`.

## Changing format

**Actions › Change Format…** converts an archive, for example from RAR to ZIP, or from ZIP to XIZ.

- **Files go straight into the new archive** without being extracted to disk.
- **Entries whose codec both formats share are copied** without recompressing them:
  - ZIP ↔ 7z: stored, Deflate, Deflate64, bzip2, LZMA;
  - 7z LZMA2 → ZIP xz;
  - ZIP Deflate, bzip2, Zstandard, xz → tar.gz, .bz2, .zst, .xz;
  - ZIP Zstandard → XIZ.
- **The new archive is verified before it gets its name**: same entries, same sizes, same checksums.
- **Move the original to the Trash once the new archive is verified** is optional.
- **When something would be lost**, Xipper lists it and asks you to confirm (**I understand what will be lost**): signatures, access groups, a password, Mac attributes.

From the command line:

```bash
xipper convert --to xiz --dry-run photos.zip     # what would be copied or recompressed, and the space needed
xipper convert --to xiz --trash-original photos.zip
```

## Converting with little free space

From ZIP or 7z to XIZ, when the disk cannot hold both archives at once, **Change Format…** offers **Convert with Little Free Space**.

- **How it works:** Xipper converts one batch of files at a time. As each batch is safe in the new archive, it frees the corresponding space in the original. At the end the original is removed.
- **If the conversion stops** (you cancel it, the Mac sleeps, the power goes out), reopening the original shows a banner with **Resume**. Before any of the original was freed you can also cancel, and the original stays as it was.
- **A password on the new archive:** resume in Terminal with `xipper convert --to xiz --little-space --encrypt`.

This was tested by killing the conversion at random 30 times, and by switching off a macOS virtual machine at random 20 times during the conversion, sometimes twice in a row. Every time it resumed and ended with an archive identical to the original.

From the command line:

```bash
xipper convert --to xiz --little-space big.zip      # also resumes an interrupted conversion
xipper convert --abandon big.zip                    # give up, if nothing of the original was freed yet
```

## Updating an archive from a folder

**Update from a Folder…** (inspector, XIZ **Versions** section) brings an archive in line with a folder:
- new or changed files are added;
- files that are gone are removed.

In XIZ the previous state stays available as a version, and only what changed is written.

```bash
xipper update --dry-run backup.xiz ~/Documents    # what would change
xipper update backup.xiz ~/Documents
```

`update` works with the other formats too, by rebuilding the archive.

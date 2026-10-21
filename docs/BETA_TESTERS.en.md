# Xipper 0.9.0 beta4: notes for testers

*[Italiano](BETA_TESTERS.md) · English*

Thanks for trying Xipper! It is an archiver for Macs with Apple Silicon (M1 or later) and **macOS 26 or later**. It creates, opens, verifies and extracts archives quickly and safely. The app follows the system language (English or Italian).

## Installation
1. Open `Xipper-0.9.0-beta4.dmg` and drag **Xipper** into **Applications**.
2. **First launch.** The beta is signed with a development certificate, not an Apple Developer ID, so macOS blocks it the first time.
   - Open Xipper. At the message "Apple could not verify…", choose **Done**.
   - Go to **System Settings › Privacy & Security**, scroll to "Xipper was blocked" and click **Open Anyway**. Confirm with your password or Touch ID.
   - Or, in Terminal:

     ```bash
     xattr -dr com.apple.quarantine /Applications/Xipper.app
     ```

3. Optionally, check the download: the DMG's SHA-256 is in the `.sha256` file next to it.

## Finder integration
On first launch Xipper shows a welcome screen with three optional steps: the Finder extension, Xipper as the default app for archives, and the `xipper` command in Terminal. You can reopen it from **Help › Welcome to Xipper**.

- **Xipper menu and toolbar button** (Finder Sync): go to **System Settings › General › Login Items & Extensions › Finder Extensions** and turn on **Xipper in the Finder**. The context menu then shows **Xipper ▸** with:
  - Compress;
  - Extract Here;
  - Verify;
  - Open in Xipper.

  For the toolbar button: right-click the Finder toolbar › **Customize Toolbar…** › drag "Xipper".
- **Quick Actions / Services:** **Compress with Xipper**, **Extract with Xipper**, **Verify with Xipper**, in the context menu under **Quick Actions** or **Services**. If they are missing, enable them in **System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders**.
- **Quick Look:** select an archive in the Finder and press Space to see its contents. Archive icons show the format (and, for ZIPs, the number of files).
- **Shortcuts:** search for "Xipper" in the Shortcuts app: Compress, Extract, Verify and List Contents.

Finder actions always create new files next to the originals (`name.zip`, `name 2`…) and never overwrite anything.

## What to try

| Area | Try | What to expect |
|---|---|---|
| Compress | Drop files and folders in the window, change name, folder, format and level, then **Compress** | A panel with speed and remaining time; at the end, tiles with size, time and speed |
| Password | With ZIP or 7z: **Password**, then reopen the archive | A password prompt; a wrong one shows "Wrong password" |
| Open | Double-click a .zip / .7z / .tar.gz / .tar.zst / .tar.xz / .aar | Browser with folders, preview and details |
| Extract | **Extract** (next to the archive), or select entries, or ⌥ + **Extract** | The sheet with destination, structure and conflicts: "Keep Both" / "Replace" (to the Trash) / "Skip" |
| Verify | **Verify** in the browser or from the Finder | "All N entries are intact", or the damaged entries in the window |
| Cancel and pause | A big archive at **Maximum**, then **Pause** and **Cancel** | It pauses, resumes and stops at once; no partial file is left behind |
| Disk full | Compress onto an almost full USB stick | "Out of disk space", with **Try Again** / **Save Elsewhere…** |
| Genomics | Compress a `.vcf`: it becomes a BGZF `.vcf.gz`; then `tabix -p vcf` | Indexable by tabix / bcftools |
| Security | Open a zip downloaded from the Internet and extract it | Extracted files stay quarantined (Gatekeeper checks them) |
| Quick Look | In the browser select an image or a PDF and press Space | The preview opens and follows the selection |
| Drag | Drag a file or folder from the browser to the Desktop | It is extracted there |
| Keychain | Open an encrypted ZIP, turn on "Remember in Keychain", reopen it | The second time Touch ID is enough |
| Notifications and Dock | Start a long job and switch to another app | A progress bar on the Dock icon and a notification at the end |
| AI assistants | **Settings › Integrations**: add a folder, then **Copy Command for Claude Code** | Claude Code sees the "xipper" server |

## Known limitations of beta4
- **RAR** is not supported yet (planned, read only), nor is ZIP Deflate64.
- **lz4 and brotli** can be opened, verified and extracted, but not created.
- Encrypted Apple Archives (AEA) need a password of at least 20 characters: a macOS limit.
- **Mac attributes** in ZIPs are saved only with the option in **Settings › Formats** (a `__MACOSX` folder, like the Finder's).
- The Finder extension only reads the names of the selected files and hands the request to the app; it never reads file contents.
- Saved passwords belong to the archive's path: if you move the archive, Xipper asks again.
- Watched folders are not there yet.
- **XIZ** (Settings › General › Experimental features) is a BETA: the format may change before version 1 and does not support passwords yet. Keep a copy in a standard format too.

## Reporting a problem
Open an issue at <https://github.com/nicolorisitano82/xipper/issues> with:
- the macOS version and Mac model;
- what you did, what you expected and what happened;
- if possible, a sample archive (or how to make one).

For problems with AI assistants, attach the relevant lines of `~/Library/Logs/Xipper/mcp-audit.jsonl`. It contains no passwords and no file contents.

## Updates
Once a day Xipper asks GitHub whether there is a new version; you can also use **Xipper › Check for Updates…**. If there is one, it asks before downloading it: the disk image goes to **Downloads** and is checked against the release's SHA-256. Xipper then opens it and quits, and you drag Xipper into **Applications** as the first time. The daily check can be turned off in **Settings › General › Updates**.

## Privacy
Xipper collects no data. Its only Internet connection is the update check on GitHub, which sends only the app's name and version, and can be turned off. Everything else happens on your Mac.

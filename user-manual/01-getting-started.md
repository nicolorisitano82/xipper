# 1. Getting started

## Requirements

- A Mac with Apple silicon (M1 or later). Intel Macs are not supported.
- macOS 26 or later. A few features need macOS 27: the Apple codecs LZRAVEN and LZMESH ([chapter 6](06-xiz.md#apple-codecs)).

## Installing

1. Download `Xipper-3.2.0.dmg` from the [releases page](https://github.com/nicolorisitano82/xipper/releases).
2. Optionally, check the download. The `.sha256` file next to the disk image holds its fingerprint:

   ```bash
   shasum -a 256 -c Xipper-3.2.0.dmg.sha256
   ```

3. Open the disk image and drag **Xipper** into **Applications**.

### First launch

Xipper is signed with its own certificate, not with an Apple Developer ID, so macOS blocks it the first time you open it.

1. Open Xipper. When macOS says the developer cannot be verified, choose **Done**.
2. Open **System Settings › Privacy & Security**, scroll to "Xipper was blocked" and click **Open Anyway**. Confirm with your password or Touch ID.

Alternatively, in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Xipper.app
```

This is needed only once per installation.

## Welcome to Xipper

On first launch Xipper offers three optional steps. You can reopen them at any time from **Help › Welcome to Xipper**.

1. **The Finder extension.** Adds the Xipper menu and toolbar button in the Finder. macOS asks you to enable **Xipper in the Finder** in **System Settings › General › Login Items & Extensions › Finder Extensions**. See [chapter 8](08-finder-shortcuts.md).
2. **Default app for archives.** Double-clicking an archive opens it in Xipper.
3. **The `xipper` command in Terminal.** Xipper links its command into `/opt/homebrew/bin` or `/usr/local/bin` when it can write there. Otherwise it copies to the clipboard the command that does it with an administrator password. See [chapter 10](10-command-line.md).

## The main window at a glance

- **Empty window:** drop files or folders on it to create an archive. Drop an archive on it, or use **File › Open Archive…** (⌘O), to open one.
- **An open archive** shows the browser:
  - the contents in a table;
  - the toolbar: **Extract**, **Verify**, **Mount**, **Actions**, **Info**;
  - the inspector on the right, with format, compression, signatures, versions and recovery data.
- **Jobs** (compressing, extracting, verifying) show their progress in the window, and also in the menu bar if you enable the icon. You can keep working while they run.

## Updates

Once a day Xipper asks GitHub whether a newer version exists. You can also check by hand with **Xipper › Check for Updates…**.

When there is one, Xipper downloads it only if you agree. It checks the download against its SHA-256 and opens the disk image; you drag Xipper into **Applications** as the first time.

Xipper only offers its own releases. Other products published in the same place, such as Xipper Forensic, are never offered. You can turn the daily check off in **Settings › General › Updates**.

## Privacy

Xipper collects no data.

- **The update check** is its only connection to the Internet.
- **Signatures:** if you configure an RFC 3161 time-stamp authority ([chapter 6](06-xiz.md#time-stamps)), Xipper also contacts that authority when it signs.
- **AI assistants:** a log of their file operations is kept on your Mac only ([chapter 11](11-ai-assistants.md)).

## Languages and accessibility

Xipper speaks English, Italian, German, French, Spanish, Japanese and Simplified Chinese, following the language of macOS. Job progress is announced to VoiceOver.

## Uninstalling

1. Quit Xipper and drag it from **Applications** to the Trash.
2. If you linked the command, remove it:

   ```bash
   rm /opt/homebrew/bin/xipper /usr/local/bin/xipper 2>/dev/null
   ```

3. Optional clean-up:
   - your keys and saved passwords are in the login Keychain. Delete them in **Settings › Keys** and **Settings › Security** before uninstalling, or later with Keychain Access;
   - settings are in `~/Library/Preferences`, whose file name starts with `app.xipper`;
   - the AI-assistant log is in `~/Library/Logs/Xipper`.

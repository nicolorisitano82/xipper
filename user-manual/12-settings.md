# 12. Settings reference

**Xipper › Settings…** (⌘,) has seven tabs.

## General

| Setting | What it does |
|---|---|
| **Default format**, **Compression** | Format and level for new archives, Quick Actions and Services |
| **Show the result in the Finder when done** | Selects the new archive or folder in the Finder at the end of a job |
| **Also extract archives inside** | Extracts nested archives up to 3 levels ([chapter 3](03-opening-and-extracting.md#archives-inside-archives)) |
| **Recovery Data › Create PAR2 recovery data after every compression** | Recovery data for every new archive: inside XIZ archives, `.par2` files for the others |
| **Redundancy** | 5%, 10% or 20% |
| **Check XIZ archives with recovery data every month** | A quiet background check |
| **Updates › Check for updates every day** | The only connection Xipper makes on its own; **Check for Updates…** checks now |

## Formats

**ZIP**

| Setting | What it does |
|---|---|
| **Method** | Deflate (works everywhere), Zstandard, bzip2, LZMA, xz, or No compression |
| **Don't recompress already compressed files** | Photos, videos and archives are stored as they are |
| **Include hidden Mac files** | `.DS_Store`, `._*` |
| **Save Mac tags and attributes** | In a `__MACOSX` folder, like the Finder |
| **Windows-compatible names** | Renames entries Windows cannot extract |

**7z**

| Setting | What it does |
|---|---|
| **Solid compression** | Smaller archives, slower extraction of a single file |
| **With a password, also encrypt file names** | Hides the file names along with the content |

**XIZ** ([chapter 6](06-xiz.md))

| Setting | What it does |
|---|---|
| **"Maximum" level with LZMA2** | About 10% smaller for apps and source code, slower to open (Xipper 2.6+) |
| **Apple codecs (LZRAVEN and LZMESH)** | macOS 27 only |
| **Smaller PNGs, PDFs and documents** | Xipper 3.0+ |
| **Smaller CSV Tables** | Xipper 3.1+ |
| **Smaller AI Models** | Xipper 3.1+ |
| **Smaller JPEG photos** | Xipper 2.7+ |

## Security

| Setting | What it does |
|---|---|
| **Quarantine files extracted from downloaded archives** | Keeps macOS's protection on what comes from the Internet (on by default) |
| **Symbolic links** | **Only inside the destination folder** (default), **All (trusted archives)**, **None** |
| **Zip bomb protection** | **Standard (1000:1)**, **Strict (100:1)**, **Permissive (100,000:1)** |
| **Archive passwords › Require Touch ID to use saved passwords** | Touch ID before a saved password is used |
| **Saved in Keychain**, **Forget All Passwords** | The saved archive passwords, and how to forget them all |

## Keys

([chapter 7](07-keys.md))

| Setting | What it does |
|---|---|
| **My identities** | **New Identity…** (Post-quantum or Classic), **Import…**, and for each identity copy, **Export…**, **Delete…** |
| **Signing keys** | **New Signing Key…** (Post-quantum or Classic), **Import…**, the same actions per key |
| **Sign new XIZ archives with** | The key that signs by default, or none |
| **Also sign changes to signed archives** | Signs every edit of an archive that is already signed |
| **Name in signatures** | The name shown in the history |
| **Time-stamp authority (URL)** | An RFC 3161 authority, or none |

## Integrations

| Setting | What it does |
|---|---|
| Finder extension | Status and a button to enable it in System Settings |
| **Menu bar icon** | Running jobs in the menu bar |
| **AI Assistants (MCP)** | Allowed folders (**Add Allowed Folder…**, **Remove**) and **Read-only (list and verify only)** ([chapter 11](11-ai-assistants.md)) |

## Genomics

| Setting | What it does |
|---|---|
| **Compress VCF, BED, GFF, FASTA, FASTQ and SAM as BGZF** | bgzip-compatible output (on by default) |
| **Also create the .gzi index** | The index for random access in BGZF files |

## Performance

| Setting | What it does |
|---|---|
| **Performance cores** / **Efficiency cores** | Which cores Xipper uses |
| **Work in the background on the efficiency cores** | Uses less energy and takes longer. Good for big jobs you are not waiting for |

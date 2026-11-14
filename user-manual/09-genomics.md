# 9. Genomics

Xipper knows the file formats of sequencing data and writes them the way the standard tools (samtools, bcftools, tabix, htslib) expect.

## BGZF instead of gzip

**Settings › Genomics › Compress VCF, BED, GFF, FASTA, FASTQ and SAM as BGZF** is on by default.

**BGZF** (blocked gzip, what `bgzip` writes):
- can be read by any `gunzip`;
- is the format tabix, bcftools and samtools require to read a file at random positions;
- with **Also create the .gzi index**, Xipper also writes the `.gzi` file.

Inside archives, BAM, CRAM and BCF files are never compressed again: they are compressed already.

```bash
xipper bgzip calls.vcf                  # calls.vcf.gz, bgzip-compatible
xipper bgzip -i reads.fastq             # with the .gzi index
xipper bgzip --convert old.vcf.gz       # a plain .gz recompressed as BGZF, in place
xipper bgzip -t calls.vcf.gz            # check every block and the end marker
```

## BAM ↔ CRAM 3.1

CRAM is usually 30–50% smaller than BAM, and samtools reads it. Open a `.bam` or `.cram` in Xipper and use **Convert to CRAM…** or **Convert to BAM…**. Xipper asks for the reference FASTA: the one the alignments were made with, uncompressed, with its `.fai` if present.

```bash
xipper cram -r GRCh38.fa sample.bam                 # sample.cram (CRAM 3.1)
xipper cram -r GRCh38.fa --version 3.0 sample.bam   # CRAM 3.0 for older readers
xipper cram -r GRCh38.fa sample.cram                # back to BAM (MD/NM tags added, as samtools does)
```

The inspector of a BAM or CRAM shows:
- the reference sequences, the sort order and the read groups;
- the number of reads and containers;
- **Create index (.crai)** for CRAM files.

CRAM files are not browsed like archives: convert them to BAM to read the alignments.

## Indexes

Xipper builds the indexes htslib tools use:

| Data | Index | Command |
|---|---|---|
| BAM | `.bai` (or `.csi` with `-C`) | `xipper index sample.bam` |
| CRAM | `.crai` | `xipper index sample.cram` |
| BCF | `.csi` | `xipper index calls.bcf` |
| FASTA / FASTQ | `.fai` (+ `.gzi` if BGZF) | `xipper index GRCh38.fa` |
| VCF, BED, GFF, SAM (BGZF) | `.tbi` (or `.csi`) | `xipper index calls.vcf.gz` or `xipper tabix -p vcf calls.vcf.gz` |

For positions beyond 512 Mbp, use CSI indexes (`-C`).

## Checks

`xipper index-check` verifies data files and their indexes:
- BGZF blocks and the end marker;
- headers;
- the CRCs of CRAM containers and CRAM's end container;
- every `.tbi`, `.csi`, `.bai`, `.gzi` and `.crai` found next to the data, against it.

```bash
xipper index-check sample.cram calls.vcf.gz
```

## Checksum manifests

For sending data to repositories or collaborators, `xipper manifest` writes checksum lists:
- `sha256sum` or `md5sum` text;
- or JSON with DRS fields: sha-256, md5, crc32c, and also sha512t24u.

```bash
xipper manifest create -o delivery.json ~/Delivery
xipper manifest verify delivery.json
```

## Tables of regions

BED files and other delimited tables compress much better in XIZ with **Smaller CSV Tables** ([chapter 6](06-xiz.md#smaller-files-without-losing-anything)).

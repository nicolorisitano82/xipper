# 14. Signed documents (.p7m, signed PDFs, ASiC)

From 3.3 Xipper checks and makes the signed documents used in Italy and in the rest of the EU:
- **`.p7m`** files (CAdES): a document wrapped in one or more signatures, also nested (`.pdf.p7m.p7m`);
- **signed PDFs** (PAdES), including document time-stamps;
- **ASiC containers** (`.asics`, `.asice`, `.scs`, `.sce`) with CAdES signatures.

Xipper checks signatures technically. Whether a signature has legal value in a specific case is for an expert to assess.

## Verifying a signature

- **`.p7m` and ASiC files** open in the **Signed document** window when you double-click them or drop them on Xipper.
- **Signed PDFs** open in Preview as usual: use **File › Verify Signature…** to check them in Xipper.

The window shows a verdict at the top, then one card per signature:

| Verdict | Meaning |
|---|---|
| **Valid qualified signature** (QES) | The certificate is qualified, the key was on a qualified device (a signature smart card or a remote signature service) and the issuer is on the EU trusted list. In the EU it has the legal effect of a handwritten signature |
| **Valid signature with a qualified certificate** | Qualified certificate, but the list does not say the key was on a qualified device |
| **Valid signature, certificate not qualified** | Intact, and the certificate leads to an authority this Mac trusts, but not a qualified one |
| **Signature intact, signer not verified** | The document has not changed since it was signed, but nothing vouches for who signed it (for example a self-made certificate) |
| **Invalid** | The document was changed, the signature does not match, or the certificate was revoked before the signature |

Each card gives:
- **who signed**: name, tax code (codice fiscale) when the certificate has one, organization;
- **who issued the certificate**, and the qualified service on the trusted list;
- **time**: the time-stamp, when there is one, otherwise the time declared by the signer's computer (which proves nothing by itself);
- **integrity**: whether the document is the one signed;
- **validity**: whether the certificate was valid at the time of signing;
- **revocation**: not revoked, revoked (and when), revoked *after* the signature (the signature stays valid), or not checked.

Nested `.p7m` files show the inner signatures as "Inner signature, level N". A signed PDF changed after a signature says so on that signature's card.

Toolbar:
- **Open Document** opens the signed document with its usual app (a read-only copy);
- **Extract Document…** saves it without the signature envelope;
- **Add Signature…** signs a `.p7m` too ([below](#signing-a-document));
- **Copy Report** copies a text report of the check;
- **Verify Again** repeats the check.

### Online checks

To say whether a signature is qualified, Xipper needs the EU **trusted list** (for Italy, AgID's). To say whether a certificate was revoked, it asks the issuing authority (OCSP or CRL). Both need the network.

The first time you open a signed document Xipper asks whether it may make these connections. It makes them only when you verify a signature. Without them it uses the list already downloaded and the revocation data inside the file, and the report says "not checked" where it could not check. Change your mind in **Settings › Security › Signed documents**.

## Signing a document

You need a **signature certificate**: on a smart card or token (Italian CNS and signature cards, with the reader and the card's driver installed), or imported into the Keychain. With a qualified certificate on a qualified card, the result is a qualified electronic signature.

1. **File › Sign Digitally…** and choose the file. To add your signature to a `.p7m`, choose the `.p7m`, or use **Add Signature…** in its window.
2. **Sign with**: the certificate. Qualified certificates and those meant for signing come first; **Show all certificates** lists the others. **Read the certificates again** after inserting a card.
3. For a `.p7m`, choose the **Signature type**:
   - **Parallel (beside the others)**: one more signature on the same document; the `.p7m` is updated in place;
   - **Nested (over the others)**: you sign the whole `.p7m`, like a countersignature; the result is `name.p7m.p7m`.
4. **Time-stamp** (optional): the URL of an RFC 3161 service and, if it wants one, a user name and password. Qualified time-stamps need an account with a provider, often the one that issued your signature. The URL and user are remembered; the password is not.
5. **Sign Document**. The card may ask for its PIN in a macOS window.

The result is `name.ext.p7m` next to the file (CAdES-BES, or CAdES-T with a time-stamp), with the document inside, SHA-256, and the signing certificate bound to the signature. Before the file is written, Xipper checks every signature in it. If the time-stamp service does not answer, nothing is written.

## From Terminal

```bash
xipper sig verify contract.pdf.p7m                     # exit 3 if not every signature is valid
xipper sig verify --online --json signed.pdf          # trusted list and revocation online, JSON report
xipper sig extract -o contract.pdf contract.pdf.p7m   # the document inside
xipper sig certificates                               # signing certificates (Keychain, smart cards)
xipper sig sign --certificate "ADA ROSSI" contract.pdf
xipper sig sign --certificate "ADA ROSSI" --parallel contract.pdf.p7m
xipper sig sign --certificate "ADA ROSSI" --timestamp https://tsa.example/ --tsa-user ada contract.pdf
```

The time-stamp password comes from `XIPPER_TSA_PASSWORD` or is asked in Terminal. See [chapter 10](10-command-line.md#signed-documents).

## Limits

- XAdES signatures (XML) in ASiC containers are listed but not verified.
- Signing makes `.p7m` files only (not signed PDFs or ASiC).
- Only the Italian trusted list is offered for now.

# 7. Keys

XIZ uses two kinds of keys, both kept in your login Keychain and managed in **Settings › Keys**:

| Kind | What it is for | Public part looks like |
|---|---|---|
| **Identity** | Receiving archives: someone encrypts an archive (or a reserved folder) for your public key, and only your identity opens it | `xizpq1…` (post-quantum) or `xizpk1…` (classic) |
| **Signing key** | Signing your archives and changes, so others can check who made them | `xizsigpq1…` (post-quantum), `xizsigse1…` (Secure Enclave) or `xizsig1…` (classic) |

Secret keys never leave the Keychain unless you export them. Touch ID protects their use.

## Post-quantum or classic

A large quantum computer, if one is ever built, would break X25519 and Ed25519. Data recorded today could then be decrypted ("harvest now, decrypt later"), and signatures could be forged.

| Key | Post-quantum (recommended) | Classic |
|---|---|---|
| **Identities** | **X-Wing**: ML-KEM-768 + X25519. An archive encrypted for it stays private even if one of the two is broken. Senders need Xipper 3.0+ | X25519. Works with every version since 2.2 |
| **Signing keys** | **Ed25519 + ML-DSA-65** (FIPS 204). Both sign every version, and the signature counts only if both verify. Checking it needs Xipper 3.2+ | Ed25519. Checked by every version since 2.2 |

Use the classic kind only when someone must read or check your archives with an older Xipper.

## Creating keys

- **Identity:** **Settings › Keys › New Identity…**. The default is post-quantum; the menu also offers **Classic (X25519)**.
- **Signing key:** **Settings › Keys › New Signing Key…**. The default is post-quantum; the menu also offers **Classic (Ed25519)**.

From Terminal (keys created this way are shared with the app):

```bash
xipper keygen --pq --keychain "Me"                  # post-quantum identity
xipper keygen --signing --pq --keychain "Work"      # hybrid signing key
xipper keygen --signing -o work.key                 # classic signing key in a file (mode 600)
```

## Keys in the Secure Enclave

**Settings › Keys › New Signing Key… › In the Secure Enclave (cannot be copied)…** makes a signing key inside your Mac's Secure Enclave. The key never leaves it: nobody can copy it, not even you, and malware cannot steal it. It signs with P-256 and ML-DSA-65 together, so it is post-quantum like the hybrid keys.

The price: **the key is lost with the Mac**. If the Mac breaks, is erased or replaced, signatures already made stay verifiable, but you cannot sign anything else with that key. Keep another key, or a certificate, for archives that must outlive the Mac. These keys have no **Export…**. Checking their signatures needs Xipper 3.3+.

```bash
xipper keygen --signing --secure-enclave --keychain "This Mac"
```

Apple Archives cannot be signed with these keys (their signature needs an Ed25519 key).

## Certificates

Signature certificates in the Keychain or on a smart card (valid, meant for signing) appear under **Settings › Keys › Sign new XIZ archives with** and in the XIZ sheet's **Signature**. Signatures made with them carry your certified name; the card asks for its PIN when you sign. They also sign documents as `.p7m` ([chapter 14](14-signed-documents.md)).

## Using them

- **Send someone your public key:** use the copy button next to the key. A post-quantum key is long (an identity is 1.6 KB, a signing key 2.6 KB) and is meant to be pasted, not read. Where space is short, Xipper shows a signing key as `xizsigpq1:` plus a 128-bit fingerprint.
- **Encrypt for someone:** paste their key as a recipient in **Access** ([chapter 6](06-xiz.md#reserved-folders-recipients-and-custodians)).
- **Sign:** choose the key in **Settings › Keys › Sign new XIZ archives with**. **Name in signatures** is the name shown in signatures.
- **Open archives encrypted for you:** Xipper tries your identities automatically. In Terminal, use `--identity keychain:*` for all of them, or `--identity keychain:NAME` for one.
- **Sign from Terminal:** `--sign keychain:NAME` or `--sign FILE`.

## Exporting and importing

- **Export…** (the ⋯ menu next to a key) writes the key to a file, secret included. Keep it as safely as a password; it is the only backup if the Keychain is lost.
- **Import…** reads a key file made by `xipper keygen` or exported from Xipper.

## Deleting

**Delete…** removes a key from the Keychain.
- **Identity:** archives encrypted only for it can no longer be opened.
- **Signing key:** past signatures stay valid, but you can't sign with that key any more.

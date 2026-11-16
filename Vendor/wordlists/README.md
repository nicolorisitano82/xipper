# Word lists for passphrases

Data files, not compiled into Xipper: the app bundles them in `Contents/Resources` (copies in
`App/Xipper/Wordlists`, checked by `XizKeyHardeningTests`), and `Passphrase` reads them at run time.

| File | Source | License |
|---|---|---|
| `eff_large_wordlist.txt` | Electronic Frontier Foundation, «EFF's New Wordlists for Random Passphrases» (2016), <https://www.eff.org/dice> | CC BY 3.0 US (attribution: Electronic Frontier Foundation) |
| `word_list_diceware_it-IT-4.txt` | Tarin Gamberini, «Lista di parole Diceware in italiano», version 4 (29/09/2019), <https://www.taringamberini.com/it/diceware_it_IT/lista-di-parole-diceware-in-italiano> | GPL-3.0-or-later (`GPL-3.0.txt`); kept as a separate file, unmodified, with its header (owner's decision of 16/11/2026) |

Both have 7776 entries (five dice, `11111`–`66666`), so a word is 12.9 bits and six words are 77 bits.

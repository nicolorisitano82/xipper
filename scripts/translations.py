#!/usr/bin/env python3
"""Languages beyond Italian and English for the String Catalogs (2.7).

Each language is scripts/translations/<lang>.json:
  {"strings": {key: "text" | {"one": "...", "other": "..."}}, "services": {Italian service name: "text"}}
Keys are the Italian source strings. Keys with plural forms (they have `variations` in Italian or
English) take {"one", "other"}; Japanese and Chinese have no plural, so a plain string is enough.
Every placeholder of the key (%@, %lld, %%) must be in the translation; when their order
changes they are numbered (%1$@, %2$lld), as in the English catalog.

Run after scripts/sync-strings.sh and scripts/translations-en.py: fills the catalogs and the
ServicesMenu.strings of each language, and lists missing or broken translations.
Usage:
  python3 scripts/translations.py                  fill every language
  python3 scripts/translations.py --check de       only check one language
  python3 scripts/translations.py --export FILE    the strings to translate, with English and plural info
"""
import json, pathlib, re, sys

LANGS = ["de", "fr", "es", "ja", "zh-Hans"]
NO_PLURAL = {"ja", "zh-Hans"}
ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGS = sorted((ROOT / "App").glob("*/Localizable.xcstrings"))
SERVICES = ROOT / "App/Xipper/en.lproj/ServicesMenu.strings"
TOKEN = re.compile(r"%(?:(\d+)\$)?(@|lld|ld|d|llu|lu|u|f|\.\df|%)")


def placeholders(text):
    """{(position, type)} of the arguments, and the number of literal %%."""
    args, percent, n = set(), 0, 0
    for m in TOKEN.finditer(text):
        if m.group(2) == "%":
            percent += 1
            continue
        n += 1
        args.add((int(m.group(1)) if m.group(1) else n, m.group(2)))
    return args, percent


def source():
    """key → (English text or plural dict, has plural), over every catalog."""
    out = {}
    for catalog in CATALOGS:
        for key, entry in json.loads(catalog.read_text())["strings"].items():
            if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
                continue
            locs = entry.get("localizations", {})
            en = locs.get("en", {})
            if "variations" in en:
                p = en["variations"]["plural"]
                english = {k: v["stringUnit"]["value"] for k, v in p.items()}
            else:
                english = en.get("stringUnit", {}).get("value", key)
            plural = "variations" in en or "variations" in locs.get("it", {})
            out[key] = (english, plural)
    return out


def services():
    return dict(re.findall(r'^"(.*)" = "(.*)";$', SERVICES.read_text(), re.M))


def check(lang, data, keys):
    problems = []
    strings = data.get("strings", {})
    for key, (english, plural) in keys.items():
        value = strings.get(key)
        if value is None:
            problems.append(f"missing: {key!r}")
            continue
        forms = value if isinstance(value, dict) else {"other": value}
        if plural and lang not in NO_PLURAL and set(forms) != {"one", "other"}:
            problems.append(f"needs one/other: {key!r}")
        if not plural and isinstance(value, dict):
            problems.append(f"not a plural key: {key!r}")
        want = placeholders(key)
        for form, text in forms.items():
            if not isinstance(text, str) or (not text.strip() and key.strip()):
                problems.append(f"empty: {key!r}")
                continue
            got = placeholders(text)
            # "one" may drop the count (e.g. "un elemento"), as the Italian and English forms do.
            if got != want and not (form == "one" and got[0] <= want[0] and got[1] == want[1]):
                problems.append(f"placeholders {sorted(got[0])} {got[1]}% ≠ {sorted(want[0])} {want[1]}%: {key!r} → {text!r}")
    for key in strings:
        if key not in keys:
            problems.append(f"unknown key (stale?): {key!r}")
    for name in services():
        if name not in data.get("services", {}):
            problems.append(f"missing service: {name!r}")
    return problems


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def fill(lang, data):
    strings = data["strings"]
    for catalog in CATALOGS:
        doc = json.loads(catalog.read_text())
        for key, entry in doc["strings"].items():
            if key not in strings:
                continue
            value = strings[key]
            locs = entry.setdefault("localizations", {})
            if isinstance(value, dict) and lang not in NO_PLURAL:
                locs[lang] = {"variations": {"plural": {k: unit(v) for k, v in value.items()}}}
            else:
                locs[lang] = unit(value["other"] if isinstance(value, dict) else value)
        catalog.write_text(json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n")
    lproj = ROOT / f"App/Xipper/{lang}.lproj"
    lproj.mkdir(exist_ok=True)
    lines = ["/* Finder Services / Quick Actions (NSServices in Info.plist). */"]
    lines += [f'"{k}" = "{v}";' for k, v in data["services"].items()]
    (lproj / "ServicesMenu.strings").write_text("\n".join(lines) + "\n")


def main(argv):
    keys = source()
    if argv[:1] == ["--export"]:
        rows = [{"key": k, "en": en, "plural": p} for k, (en, p) in sorted(keys.items())]
        pathlib.Path(argv[1]).write_text(json.dumps({"strings": rows, "services": services()}, ensure_ascii=False, indent=1) + "\n")
        print(f"{len(rows)} strings, {len(services())} services")
        return 0
    only_check = argv[:1] == ["--check"]
    langs = argv[1:] if only_check else (argv or LANGS)
    failed = False
    for lang in langs:
        path = ROOT / f"scripts/translations/{lang}.json"
        if not path.exists():
            print(f"{lang}: no {path.name}")
            failed = True
            continue
        data = json.loads(path.read_text())
        problems = check(lang, data, keys)
        if problems:
            failed = True
            print(f"{lang}: {len(problems)} problems", *problems[:40], sep="\n  ")
        elif not only_check:
            fill(lang, data)
        print(f"{lang}: {'ok' if not problems else 'not written'} ({len(data.get('strings', {}))} strings)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

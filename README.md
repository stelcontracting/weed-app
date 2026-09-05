# STEL Weed ID

Photograph a weed, find every herbicide registered for it in Australia, open the
approved APVMA label. Installs to a phone or tablet home screen and the weed
search works with no signal.

Live at **https://stelcontracting.github.io/stel-weed/**

## What it does

- **Identify from a photo** — Pl@ntNet returns candidate species with confidence
  scores; you confirm which one is right. It never picks silently.
- **Search a weed by name** — works fully offline. This is the part that carries
  the value in a paddock.
- **See what is registered** — herbicides for that weed, narrowed to the
  situation you are in (pasture, fenceline, roadside, forestry, non-crop…),
  grouped by active constituent so modes of action can be rotated.
- **Open the label** — the official APVMA approved label PDF for that product.
- **Look up a product** — what is this drum in the shed actually for.

## What it deliberately does not do

**It never states an application rate.** PubCRIS does not publish rates, and a
wrong rate is an off-label offence. The rate, water volume, withholding period
and whether aerial or drone application is permitted are all on the label, which
is one tap away and is the legal document.

It also does not claim a product is suitable for drone application. Flagging that
would mean reading the text of all 3,661 labels — a worthwhile next step, but not
something to guess at.

## Data

Everything comes from the [APVMA PubCRIS open
dataset](https://www.data.gov.au/data/dataset/apvma-pubcris-dataset-for-registered-agricultural-and-veterinary-chemical-products-and-approved-acti)
(CC BY 3.0 AU, refreshed weekly). Label PDFs are served by APVMA at
`elabels.apvma.gov.au/{APVMA number}ELBL.pdf`.

Current extract: 3,661 registered herbicides, 2,059 weeds, 800,117
weed × situation × product combinations. The offline core is about 745 KB gzipped.

## Rebuilding the data

Run under Git Bash. Needs only `curl`, `gawk`, `sort` and `gzip` — no Node, no
Python, nothing to install.

```bash
./build-data.sh          # uses cached CSVs if present
./build-data.sh --fresh  # re-download (APVMA updates weekly)
```

It downloads eight PubCRIS CSVs, joins them, and writes `data/*.json`, which is
committed so the app needs no backend. The CSV cache (~170 MB) is kept in
`%LOCALAPPDATA%\stel-weed-build`, outside the repo and outside OneDrive. Override
with `BUILD_DIR=/some/path`.

The build validates itself: it fails if the index references a product, weed or
host that does not exist, or if the delta encoding goes negative.

## Two files you can edit without touching code

- **`situation-groups.txt`** — collapses PubCRIS's 2,502 host codes into the ~20
  situations that appear as chips in the app. Each line is
  `id | Display name | regex`. Currently every host used by a herbicide is
  classified; none fall through to "other".
- **`crosswalk-manual.txt`** — maps scientific names to PubCRIS weed codes. This
  is the bridge between what Pl@ntNet returns (`Sporobolus natalensis`) and what
  PubCRIS calls it (`GIANT RATS TAIL GRASS - S NATALENSIS`). Only 15 of PubCRIS's
  own aliases are proper binomials, so this file is where the accuracy comes
  from. It is weighted to Central Queensland.

When the app identifies something with no crosswalk entry, it records the name
under Setup → "Species with no APVMA match". Those are the ones worth adding.

## Shipping an update

Edit, bump the `CACHE` string in `sw.js` (currently `stel-weed-v1`), commit, push.
The service worker is network-first for the page, so phones pick up the change
next time they have signal. No reinstalling.

If `git push` fails with `User canceled device code authentication`, use
`git -c credential.gitHubAuthModes=browser push` — the tool shell has no TTY for
the device-code flow.

## Setup on a phone

1. Open the URL, then Chrome menu → **Install app** / **Add to Home screen** →
   **Install**. If you still see an address bar after opening it from the home
   screen, it is only a shortcut and the offline behaviour is lost.
2. For photo identification, get a free key at
   [my.plantnet.org](https://my.plantnet.org/) (500 identifications a day) and
   paste it into **Setup**. It is stored on the device and is never in this repo.

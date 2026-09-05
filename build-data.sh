#!/bin/sh
# ---------------------------------------------------------------------------
# STEL Weed ID — data pipeline
#
# Turns the APVMA PubCRIS open dataset into the static JSON the app ships with.
# Run it under Git Bash. Needs nothing installed beyond curl, awk, sort and gzip.
#
#   ./build-data.sh          normal run, uses cached CSVs if they are there
#   ./build-data.sh --fresh  re-download everything (APVMA update weekly)
#
# Everything it writes goes to data/. That output is committed, so the app has
# no backend and works with no signal.
# ---------------------------------------------------------------------------
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
# The CSV cache and scratch files run to ~170 MB and are all re-downloadable, so
# they are kept OUT of the repo and out of OneDrive. Override with BUILD_DIR.
if [ -n "${BUILD_DIR:-}" ]; then
  BUILD="$BUILD_DIR"
elif [ -n "${LOCALAPPDATA:-}" ]; then
  # LOCALAPPDATA arrives with backslashes; awk reads those as escape sequences
  # when a path is used in `print > file`, so normalise to POSIX form.
  if command -v cygpath >/dev/null 2>&1; then
    BUILD="$(cygpath -u "$LOCALAPPDATA")/stel-weed-build"
  else
    BUILD="$(printf '%s' "$LOCALAPPDATA" | tr '\\' '/')/stel-weed-build"
  fi
else
  BUILD="${TMPDIR:-/tmp}/stel-weed-build"
fi
CACHE="$BUILD/cache"
WORK="$BUILD/work"
OUT="$HERE/data"
BASE="https://data.gov.au/data/dataset/0de37904-43e0-4814-b21b-5b64fafefe6f/resource"

FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

mkdir -p "$CACHE" "$WORK" "$OUT"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }

# --- 0. fetch ---------------------------------------------------------------
# resource-id/filename pairs. These ids are stable; the dataset is refreshed
# weekly in place.
fetch() {
  _id=$1; _f=$2
  if [ $FRESH -eq 0 ] && [ -s "$CACHE/$_f" ]; then
    say "  cached  $_f ($(wc -c < "$CACHE/$_f") bytes)"
    return
  fi
  say "  fetch   $_f"
  curl -sSL -A "Mozilla/5.0" --max-time 600 \
    "$BASE/$_id/download/$_f" -o "$CACHE/$_f.part" || die "download $_f"
  [ -s "$CACHE/$_f.part" ] || die "$_f came back empty"
  mv "$CACHE/$_f.part" "$CACHE/$_f"
}

say "== 1/7  fetching PubCRIS =="
fetch b4bb5394-b60b-4602-8bde-2e206ffc498f product.csv
fetch 80289270-0681-44fd-be6e-0473bb4ab9a0 produse.csv
fetch 1365af46-a3db-4d54-9f25-e41f7dfce5d2 pest.csv
fetch 01ad3c71-45ac-404e-8f4a-fbbb273bd7a8 pest_alias.csv
fetch 2927e1dd-b064-411c-bc90-1e2c05b6822f host.csv
fetch eb08d8fc-bb61-4191-9a4b-a20ee44dac1f prodcon.csv
fetch de913672-c51a-483a-b467-f2f9df51f671 constit.csv
fetch 80d19f68-6282-4b46-bb2c-60af8901fd61 statereg.csv

# Shared awk helpers. Fields in this dataset are all double-quoted and no field
# contains the sequence ",", so splitting on that is safe — verified against all
# 18,582 product rows. Embedded "" escapes do occur and are unwrapped here.
AWKLIB='
function unq(s){ sub(/^"/,"",s); sub(/"$/,"",s); gsub(/""/,"\"",s); return s }
function trim(s){ gsub(/^[ \t\r\n]+/,"",s); gsub(/[ \t\r\n]+$/,"",s); return s }
function clean(s){ sub(/\r$/,"",s); return trim(unq(s)) }
function jesc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\r\n\t]/," ",s); return s }
function title(s,   i,n,w,o,t,b,c,pp){ n=split(tolower(s),w," "); o="";
  for(i=1;i<=n;i++){ t=w[i]; b=t; gsub(/[^a-z0-9]/,"",b)
    c=t; gsub(/[^a-z0-9,.-]/,"",c)
    # formulation and pack codes read as codes, not words: WG, EC, SC ...
    if (b ~ /^(wg|df|sc|ec|wp|sl|sg|me|od|cs|ew|zc|gr|xl|ds|ws|ulv|rtu|ai|lv|ib)$/) t = toupper(t)
    # a chemical name inside a product name is still a chemical name: 2,4-D
    else if (c ~ /^[0-9][0-9,]*-[a-z]+$/) { split(c,pp,"-"); if (length(pp[2])<=4) t = toupper(t)
      else t = toupper(substr(t,1,1)) substr(t,2) }
    else t = toupper(substr(t,1,1)) substr(t,2)
    o = o (i>1?" ":"") t }
  # PubCRIS writes "STUBBLE,PRIOR TO" with no space. Only add one where a letter
  # follows, so product names like "2,2-DPA" are left alone. (gensub is gawk.)
  return gensub(/,([A-Za-z])/, ", \\1", "g", o) }
# Chemical names are identifiers — an operator reads 2,4-D and MCPA, not 2,4-d.
# Sentence case, but the actual active name keeps its own capitalisation.
function chem(s,   i,n,w,o,t,b,pp){ n=split(tolower(s),w," "); o=""
  for(i=1;i<=n;i++){ t=w[i]; b=t; gsub(/[^a-z0-9,.-]/,"",b)
    if (b ~ /^[0-9][0-9,]*-[a-z]+$/) { split(b,pp,"-"); if (length(pp[2])<=4) t = toupper(t) }
    else if (b ~ /^(mcpa|mcpb|msma|dsma|tca|eptc|cmpp|tba|dpa|sma)$/) t = toupper(t)
    o = o (i>1?" ":"") t }
  return toupper(substr(o,1,1)) substr(o,2) }
# The base active, with the salt or ester stripped off. PubCRIS lists 2,4-D as
# six different salts; an operator rotating modes of action wants them under one
# heading. constit.csv has a chemical-group column but it spells the same group
# four different ways, so it is no use for this.
function base(s,   u,p,n,w){
  u = toupper(s); gsub(/\r/,"",u)
  p = index(u, " PRESENT AS"); if (p) u = substr(u, 1, p-1)
  p = index(u, " P/A ");       if (p) u = substr(u, 1, p-1)
  p = index(u, " AS THE ");    if (p) u = substr(u, 1, p-1)
  p = index(u, " AS ");        if (p) u = substr(u, 1, p-1)
  if (u ~ /(SALT|SALTS|ESTER|ESTERS)$/) { n = split(u, w, " "); u = w[1] }
  else sub(/ ACID$/, "", u)
  return chem(u) }
'

# --- 1. products ------------------------------------------------------------
say "== 2/7  products =="
grep -v '^#' "$HERE/product-types.txt" | grep '|' > "$WORK/types.tsv"
say "  product types wanted: $(wc -l < "$WORK/types.tsv" | tr -d ' ')"

# product.csv: pcode,prodtype,psched,regdate,fdesc,typedesc,hlevel1,fpname,sname,regcode,expdate,scode1
# Only current registrations (regcode R) in the agricultural category (typedesc
# starts "A"), so veterinary products can never leak in.
awk -F'","' "$AWKLIB"'
FILENAME ~ /types\.tsv$/ {
  line = $0
  p1 = index(line, "|"); if (p1 == 0) next
  rest = substr(line, p1 + 1)
  p2 = index(rest, "|"); if (p2 == 0) next
  t = trim(substr(line, 1, p1 - 1))
  grp[t] = trim(substr(rest, 1, p2 - 1))
  lbl[t] = trim(substr(rest, p2 + 1))
  next
}
FNR==1 { next }
{
  hl = clean($7); rc = clean($10); ty = clean($6)
  if (rc != "R" || ty !~ /^A/ || !(hl in grp)) next
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", clean($1), clean($8), clean($9), clean($5), clean($11), lbl[hl], grp[hl]
}' "$WORK/types.tsv" "$CACHE/product.csv" | sort -t"$(printf '\t')" -k1,1 > "$WORK/products.tsv"

NPROD=$(wc -l < "$WORK/products.tsv" | tr -d ' ')
say "  products in scope: $NPROD"
[ "$NPROD" -gt 6000 ] || die "only $NPROD products — PubCRIS schema or product-types.txt may have changed"
awk -F'\t' '{c[$6]++} END{for(k in c) printf "    %5d  %s\n", c[k], k}' "$WORK/products.tsv" | sort -rn >&2

cut -f1 "$WORK/products.tsv" > "$WORK/pcodes.txt"

# actives: prodcon (pcode,ccode,ctype,camount,cucode) joined to constit (ccode,cname,clevel1)
awk -F'","' "$AWKLIB"'
FILENAME ~ /pcodes/ { keep[$1]=1; next }
FILENAME ~ /constit/ { if(FNR>1) cname[clean($1)] = clean($2); next }
FNR==1 { next }
{
  p = clean($1); if (!(p in keep)) next
  if (clean($3) != "A") next
  c = clean($2)
  printf "%s\t%s\t%s\t%s\n", p, (c in cname ? cname[c] : c), clean($4)+0, clean($5)
}' "$WORK/pcodes.txt" "$CACHE/constit.csv" "$CACHE/prodcon.csv" > "$WORK/actives.tsv"

say "  active-constituent rows: $(wc -l < "$WORK/actives.tsv" | tr -d ' ')"

# state registration — QLD is what matters here, but keep them all
awk -F'","' "$AWKLIB"'
FILENAME ~ /pcodes/ { keep[$1]=1; next }
FNR==1 { next }
{ p = clean($1); if (!(p in keep)) next
  if (clean($3) != "R") next
  printf "%s\t%s\n", p, clean($2) }' "$WORK/pcodes.txt" "$CACHE/statereg.csv" \
  | sort -u > "$WORK/states.tsv"

# --- 2. targets -------------------------------------------------------------
say "== 3/7  target vocabulary =="
# Which pest codes do the products in scope actually target?
awk -F'","' "$AWKLIB"'
FILENAME ~ /pcodes/ { keep[$1]=1; next }
FNR==1 { next }
{ p = clean($1); if (p in keep) print clean($3) }' \
  "$WORK/pcodes.txt" "$CACHE/produse.csv" | sort -u > "$WORK/pestcodes.txt"

say "  pest codes in use: $(wc -l < "$WORK/pestcodes.txt" | tr -d ' ')"

# Not every code follows the prefix convention — Navua sedge is "NAVSE", giant
# rats tail is "ZGGR". For the stragglers, infer the kind from what sort of
# product targets them: if only herbicides list it, it is a weed.
awk "$AWKLIB"'
BEGIN { FS="\t" }
FILENAME ~ /products\.tsv$/ {
  t = $6; k = ""
  if (t == "Herbicide") k = "weed"
  else if (t == "Insecticide" || t == "Miticide" || t == "Nematicide" || t == "Snail & slug") k = "insect"
  else if (t == "Fungicide" || t == "Bactericide" || t == "Algicide") k = "disease"
  if (k != "") pk[$1] = k
  next
}
{
  n = split($0, f, "\",\"")
  if (n < 3) next
  p = clean(f[1]); w = clean(f[3])
  if (p in pk) cnt[w SUBSEP pk[p]]++
}
END {
  for (key in cnt) {
    split(key, a, SUBSEP)
    if (cnt[key] > best[a[1]]) { best[a[1]] = cnt[key]; kind[a[1]] = a[2] }
  }
  for (w in kind) print w "\t" kind[w]
}' "$WORK/products.tsv" "$CACHE/produse.csv" | sort > "$WORK/kindhint.tsv"

say "  kind inferred from product type for: $(wc -l < "$WORK/kindhint.tsv" | tr -d ' ') codes"

# PubCRIS codes the target by prefix, which is undocumented but completely
# consistent once you look at the names:
#   Z  weeds          W,I  insects        Y  diseases
#   U  mites AND vertebrate pests (split by name)
#   X  crop-growth effects            V  veterinary — never wanted here
# Everything else is label boilerplate ("REFER TO LABEL", "OPTIMISE SPRAY WATER
# PH") and is dropped. Vertebrates are dropped too: you do not spray a fox.
awk -F'","' "$AWKLIB"'
FILENAME ~ /pestcodes/ { want[$1]=1; next }
FILENAME ~ /kindhint/ { split($0, kh, "\t"); hint[kh[1]] = kh[2]; next }
FNR==1 { next }
{
  c = clean($1); if (!(c in want)) next
  d = clean($2); if (d == "") next
  u = toupper(d); f = substr(c, 1, 1)

  if (u ~ /^(REFER|SEE |CONTROL OF|OPTIMISE|PASTURE TOPPING|SPRAY |FOAM|SOFTENS|REDUCE FOAM|LONG-TERM)/) next
  if (u ~ /REFER TO|SEE LABEL|NOT SPECIFIED|MISCELLANEOUS|AS APPROVED FOR OTHER/) next
  if (f == "V") next

  # Three signals, strongest first. The prefix convention alone gets this wrong
  # ~2% of the time — "YORKSHIRE FOG", "WILD OATS" and "WHITE CLOVER" are weeds
  # that merely start with Y and W — so it is the LAST resort, not the first.
  kind = ""
  if (f == "X") kind = "growth"

  # 1. the name itself. Word boundaries matter: \<ANT\> must not match
  #    ANTHRACNOSE, \<ROT\> must not match CARROT.
  else if (u ~ /\<(APHID|APHIDS|MITE|MITES|MOTH|MOTHS|BEETLE|BEETLES|WEEVIL|WEEVILS|THRIP|THRIPS|CATERPILLAR|CATERPILLARS|BORER|BORERS|SCALE|GRUB|GRUBS|ANT|ANTS|LOCUST|LOCUSTS|HOPPER|HOPPERS|LEAFHOPPER|MEALYBUG|MEALYBUGS|WHITEFLY|PSYLLID|PSYLLIDS|NEMATODE|NEMATODES|EELWORM|SNAIL|SNAILS|SLUG|SLUGS|EARWIG|EARWIGS|SLATER|SLATERS|MILLIPEDE|MILLIPEDES|SPRINGTAIL|MAGGOT|MAGGOTS|BLOWFLY|WIREWORM|CUTWORM|ARMYWORM|ARMYWORMS|BUDWORM|WEBWORM|LOOPER|WEBSPINNING|TICK|TICKS|LARVAE|LARVA)\>/) kind = "insect"
  else if (u ~ /\<(BLIGHT|ROT|ROTS|MILDEW|RUST|WILT|CANKER|ANTHRACNOSE|SCAB|SMUT|DAMPING|MOULD|MOLD|VIRUS|BACTERIAL|FUNGUS|FUNGI|DIEBACK|NECROSIS|MOSAIC|PHYTOPHTHORA|SCLEROTINIA|BOTRYTIS|FUSARIUM|RHIZOCTONIA|PYTHIUM|ALTERNARIA)\>/) kind = "disease"

  # 2. what sort of product actually targets it — 97.9% agreement with the
  #    prefix, and right in nearly every case where the two differ.
  else if (c in hint) kind = hint[c]

  # 3. the prefix convention, for codes nothing else reached
  else if (f == "Z") kind = "weed"
  else if (f == "W" || f == "I") kind = "insect"
  else if (f == "Y") kind = "disease"
  else if (f == "U") next          # fox, rodent, rabbit — you do not spray those
  else next

  print c "\t" d "\t" kind
}' "$WORK/pestcodes.txt" "$WORK/kindhint.tsv" "$CACHE/pest.csv" | sort -u > "$WORK/targets.tsv"

NTARGET=$(wc -l < "$WORK/targets.tsv" | tr -d ' ')
say "  targets kept: $NTARGET"
awk -F'\t' '{c[$3]++} END{for(k in c) printf "    %5d  %s\n", c[k], k}' "$WORK/targets.tsv" | sort -rn >&2
[ "$NTARGET" -gt 3000 ] || die "only $NTARGET targets — the classifier is too aggressive"

cut -f1 "$WORK/targets.tsv" > "$WORK/targetcodes.txt"

awk -F'","' "$AWKLIB"'
FILENAME ~ /targetcodes/ { want[$1]=1; next }
FNR==1 { next }
{ c = clean($1); if (!(c in want)) next
  a = clean($2); if (a == "") next
  print c "\t" a }' "$WORK/targetcodes.txt" "$CACHE/pest_alias.csv" | sort -u > "$WORK/target_alias.tsv"

say "  target aliases: $(wc -l < "$WORK/target_alias.tsv" | tr -d ' ')"

# --- 3. situations ----------------------------------------------------------
say "== 4/7  situation groups =="
grep -v '^#' "$HERE/situation-groups.txt" | grep '|' > "$WORK/groups.tsv"
NGRP=$(wc -l < "$WORK/groups.tsv" | tr -d ' ')
say "  groups defined: $NGRP"

awk -F'","' "$AWKLIB"'
FILENAME ~ /groups.tsv/ {
  # Split on the FIRST TWO pipes only — everything after them is the regex,
  # which is itself full of pipes. split() here would shred it.
  line = $0
  p1 = index(line, "|"); if (p1 == 0) next
  rest = substr(line, p1 + 1)
  p2 = index(rest, "|"); if (p2 == 0) next
  gid[++ng] = trim(substr(line, 1, p1 - 1))
  gname[ng] = trim(substr(rest, 1, p2 - 1))
  grx[ng]   = trim(substr(rest, p2 + 1))
  next
}
FNR==1 { next }
{
  c = clean($1); d = clean($2); if (c=="" || d=="") next
  u = toupper(d); hit = 0; out = ""
  for (i = 1; i <= ng; i++) if (u ~ grx[i]) { out = out (hit++ ? "," : "") (i-1) }
  if (!hit) { out = ng }           # "other" bucket, appended after the file rules
  printf "%s\t%s\t%s\n", c, d, out
}' "$WORK/groups.tsv" "$CACHE/host.csv" > "$WORK/hosts.tsv"

say "  hosts mapped: $(wc -l < "$WORK/hosts.tsv" | tr -d ' ')"
say "  unmatched -> other: $(awk -F'\t' -v n="$NGRP" '$3==n' "$WORK/hosts.tsv" | wc -l | tr -d ' ')"

# --- 4. the big join --------------------------------------------------------
say "== 5/7  joining produse (this is the slow one) =="
# produse -> targetIdx, groupIdx, productIdx  and  targetIdx, productIdx, hostIdx
awk "$AWKLIB"'
BEGIN { FS="\t" }
FILENAME ~ /products\.tsv$/ { pidx[$1] = np++; next }
FILENAME ~ /targets\.tsv$/  { widx[$1] = nw++; next }
FILENAME ~ /hosts\.tsv$/    { hidx[$1] = nh++; hgrp[$1] = $3; next }
{
  # produse.csv, re-split on the quoted-CSV separator
  n = split($0, f, "\",\"")
  if (n < 3) next
  p = clean(f[1]); h = clean(f[2]); w = clean(f[3])
  if (!(p in pidx) || !(w in widx) || !(h in hidx)) next
  pi = pidx[p]; wi = widx[w]; hi = hidx[h]
  print wi "\t" pi "\t" hi > DETAIL
  ng = split(hgrp[h], g, ",")
  for (i = 1; i <= ng; i++) print wi "\t" g[i] "\t" pi > IDX
  # what this product is registered on, regardless of target — this is what
  # makes "photograph the crop, see what is registered on it" possible
  print hi "\t" pi > BYHOST
}
END { printf "  matched triples: %d\n", NR > "/dev/stderr" }
' DETAIL="$WORK/detail.raw" IDX="$WORK/idx.raw" BYHOST="$WORK/byhost.raw" \
  "$WORK/products.tsv" "$WORK/targets.tsv" "$WORK/hosts.tsv" "$CACHE/produse.csv"

# NUMERIC sort on all three columns. A plain sort -u orders these lexically
# (2 after 10), which makes the delta encoding below go negative and emit
# garbage indices. Contiguity per weed/group is what lets the emitters stream.
sort -u -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n "$WORK/idx.raw"    -o "$WORK/idx.tsv"
sort -u -t"$(printf '\t')" -k1,1n -k2,2n -k3,3n "$WORK/detail.raw" -o "$WORK/detail.tsv"
sort -u -t"$(printf '\t')" -k1,1n -k2,2n            "$WORK/byhost.raw" -o "$WORK/byhost.tsv"
say "  index rows (target x group x product): $(wc -l < "$WORK/idx.tsv" | tr -d ' ')"
say "  detail rows (target x product x host): $(wc -l < "$WORK/detail.tsv" | tr -d ' ')"
say "  by-host rows (host x product):         $(wc -l < "$WORK/byhost.tsv" | tr -d ' ')"

# --- 5. crosswalk -----------------------------------------------------------
say "== 6/7  scientific-name crosswalk =="
# Auto: many descriptions carry a binomial after a dash, and some aliases are
# binomials outright. Hand-curated entries in crosswalk-manual.txt win.
{
  awk -F'\t' '{
    d = $2
    if (match(d, / - [A-Z][A-Za-z.]+ [A-Za-z.]+/)) {
      s = substr(d, RSTART+3)
      if (s !~ /^(SEEDLING|SUPPRESSION|PRE |POST |SEED|REFER|SEE |CONTROL|EARLY|LATE)/)
        print tolower(s) "\t" $1 "\tauto"
    }
  }' "$WORK/targets.tsv"
  awk -F'\t' '$2 ~ /^[A-Z][a-z]+ [a-z]+$/ { print tolower($2) "\t" $1 "\tauto" }' "$WORK/target_alias.tsv"
  grep -v '^#' "$HERE/crosswalk-manual.txt" 2>/dev/null | grep '|' | awk -F'[ \t]*\\|[ \t]*' \
    '{ if ($1!="" && $2!="") print tolower($1) "\t" $2 "\tmanual" }'
} | awk -F'\t' '!seen[$1"\t"$2]++' | sort > "$WORK/crosswalk.tsv"

say "  crosswalk entries: $(wc -l < "$WORK/crosswalk.tsv" | tr -d ' ') ($(awk -F'\t' '$3=="manual"' "$WORK/crosswalk.tsv" | wc -l | tr -d ' ') hand-curated)"

# --- 6. emit JSON -----------------------------------------------------------
say "== 7/7  writing data/ =="

# products.json
awk "$AWKLIB"'
BEGIN { FS="\t"; print "{\"v\":1,\"products\":[" }
FILENAME ~ /actives\.tsv$/ {
  a[$1] = a[$1] (a[$1]?",":"") "[\"" jesc(chem($2)) "\"," ($3+0) ",\"" jesc($4) "\",\"" jesc(base($2)) "\"]"; next
}
FILENAME ~ /states\.tsv$/ { st[$1] = st[$1] (st[$1]?",":"") "\"" $2 "\""; next }
{
  # pcode, name, company, formulation, actives, states, expiry, type, typegroup
  printf "%s[\"%s\",\"%s\",\"%s\",\"%s\",[%s],[%s],\"%s\",\"%s\",\"%s\"]", (n++?",\n":"\n"),
    jesc($1), jesc(title($2)), jesc(title($3)), jesc(title($4)),
    ($1 in a ? a[$1] : ""), ($1 in st ? st[$1] : ""), jesc(substr($5,1,10)),
    jesc($6), jesc($7)
}
END { print "\n]}" }' "$WORK/actives.tsv" "$WORK/states.tsv" "$WORK/products.tsv" > "$OUT/products.json"

# targets.json — weeds, insects and diseases in one list, each tagged with kind
awk "$AWKLIB"'
BEGIN { FS="\t"; print "{\"v\":2,\"targets\":[" }
FILENAME ~ /target_alias\.tsv$/ { al[$1] = al[$1] (al[$1]?",":"") "\"" jesc(title($2)) "\""; next }
FILENAME ~ /crosswalk\.tsv$/    { sc[$2] = sc[$2] (sc[$2]?",":"") "\"" jesc($1) "\""; next }
{
  printf "%s[\"%s\",\"%s\",[%s],[%s],\"%s\"]", (n++?",\n":"\n"),
    jesc($1), jesc(title($2)), ($1 in al ? al[$1] : ""), ($1 in sc ? sc[$1] : ""), jesc($3)
}
END { print "\n]}" }' "$WORK/target_alias.tsv" "$WORK/crosswalk.tsv" "$WORK/targets.tsv" > "$OUT/targets.json"

# situations.json — file-defined groups plus the catch-all
awk -F'[ \t]*\\|[ \t]*' '
BEGIN { print "{\"v\":1,\"groups\":[" }
{ printf "%s[\"%s\",\"%s\"]", (n++?",\n":"\n"), $1, $2 }
END { printf "%s[\"other\",\"Other situations\"]\n]}\n", (n?",\n":"\n") }' "$WORK/groups.tsv" > "$OUT/situations.json"

# hosts.json — the exact PubCRIS wording, for the product detail card
awk -F'\t' "$AWKLIB"'
BEGIN { print "{\"v\":1,\"hosts\":[" }
{ printf "%s\"%s\"", (n++?",":""), jesc(title($2)) }
END { print "\n]}" }' "$WORK/hosts.tsv" > "$OUT/hosts.json"

# index.json — weed -> group -> product ids, deltas in base 36
awk "$AWKLIB"'
BEGIN { FS="\t"; print "{\"v\":1,\"idx\":{" }
function b36(x,  s,d){ if(x<0){ print "FATAL: negative delta — input is not numerically sorted" > "/dev/stderr"; exit 1 }
  if(x==0) return "0"; s=""
  while(x>0){ d=x%36; s=substr("0123456789abcdefghijklmnopqrstuvwxyz",d+1,1) s; x=int(x/36) } return s }
# NOTE: guard on explicit flags, never on cw!="". Index 0 arrives as the strnum
# "0", and awk compares a strnum against a string constant NUMERICALLY, so
# ("0" != "") is FALSE and the flush silently never fires — which shows up much
# later as a negative delta.
function flushg(){ if(haveg) { gout = gout (gout?",":"") "\"" cg "\":\"" plist "\""; plist=""; prev=0; haveg=0 } }
function flushw(){ flushg(); if(havew) { printf "%s\"%s\":{%s}", (n++?",\n":"\n"), cw, gout; gout=""; havew=0 } }
{
  if (!havew || $1 != cw) { flushw(); cw=$1; havew=1 }
  if (!haveg || $2 != cg) { flushg(); cg=$2; haveg=1 }
  plist = plist (plist?",":"") b36($3 - prev); prev = $3
}
END { flushw(); print "\n}}" }' "$WORK/idx.tsv" > "$OUT/index.json"

# detail.json — weed -> product -> host ids (lazy-loaded, then cached)
awk "$AWKLIB"'
BEGIN { FS="\t"; print "{\"v\":1,\"detail\":{" }
function b36(x,  s,d){ if(x<0){ print "FATAL: negative delta — input is not numerically sorted" > "/dev/stderr"; exit 1 }
  if(x==0) return "0"; s=""
  while(x>0){ d=x%36; s=substr("0123456789abcdefghijklmnopqrstuvwxyz",d+1,1) s; x=int(x/36) } return s }
function flushp(){ if(havep) { pout = pout (pout?",":"") "\"" cp "\":\"" hlist "\""; hlist=""; prev=0; havep=0 } }
function flushw(){ flushp(); if(havew) { printf "%s\"%s\":{%s}", (n++?",\n":"\n"), cw, pout; pout=""; havew=0 } }
{
  if (!havew || $1 != cw) { flushw(); cw=$1; havew=1 }
  if (!havep || $2 != cp) { flushp(); cp=$2; havep=1 }
  hlist = hlist (hlist?",":"") b36($3 - prev); prev = $3
}
END { flushw(); print "\n}}" }' "$WORK/detail.tsv" > "$OUT/detail.json"

# byhost.json — host -> every product registered on it, whatever the target.
# This is what answers "I am standing in a macadamia block, what can I use here".
awk "$AWKLIB"'
BEGIN { FS="\t"; print "{\"v\":1,\"byhost\":{" }
function b36(x,  s,d){ if(x<0){ print "FATAL: negative delta — input is not numerically sorted" > "/dev/stderr"; exit 1 }
  if(x==0) return "0"; s=""
  while(x>0){ d=x%36; s=substr("0123456789abcdefghijklmnopqrstuvwxyz",d+1,1) s; x=int(x/36) } return s }
function flushh(){ if(haveh) { printf "%s\"%s\":\"%s\"", (n++?",\n":"\n"), ch, plist; plist=""; prev=0; haveh=0 } }
{
  if (!haveh || $1 != ch) { flushh(); ch=$1; haveh=1 }
  plist = plist (plist?",":"") b36($2 - prev); prev = $2
}
END { flushh(); print "\n}}" }' "$WORK/byhost.tsv" > "$OUT/byhost.json"

# meta.json
STAMP=$(date -u +%Y-%m-%d)
cat > "$OUT/meta.json" <<META
{
  "v": 2,
  "built": "$STAMP",
  "source": "APVMA PubCRIS open dataset (data.gov.au), CC BY 3.0 AU",
  "counts": {
    "products": $NPROD,
    "targets": $NTARGET,
    "weeds": $(awk -F'\t' '$3=="weed"' "$WORK/targets.tsv" | wc -l | tr -d ' '),
    "insects": $(awk -F'\t' '$3=="insect"' "$WORK/targets.tsv" | wc -l | tr -d ' '),
    "diseases": $(awk -F'\t' '$3=="disease"' "$WORK/targets.tsv" | wc -l | tr -d ' '),
    "hosts": $(wc -l < "$WORK/hosts.tsv" | tr -d ' '),
    "index": $(wc -l < "$WORK/idx.tsv" | tr -d ' '),
    "detail": $(wc -l < "$WORK/detail.tsv" | tr -d ' ')
  }
}
META

say ""
say "== output =="
for f in "$OUT"/*.json; do
  raw=$(wc -c < "$f" | tr -d ' ')
  gz=$(gzip -c "$f" | wc -c | tr -d ' ')
  printf '  %-18s %9s raw  %9s gz\n' "$(basename "$f")" "$raw" "$gz" >&2
  [ "$raw" -gt 2 ] || die "$(basename "$f") is empty"
done
# Validate: every product id the index refers to must exist in products.json,
# and likewise every host id in detail.json. This is what catches an encoding
# or sort-order regression before it reaches a phone.
say ""
say "== validating =="
MAXP=$(cut -f3 "$WORK/idx.tsv" | sort -n | tail -1)
MAXH=$(cut -f3 "$WORK/detail.tsv" | sort -n | tail -1)
MAXW=$(cut -f1 "$WORK/idx.tsv" | sort -n | tail -1)
MAXBP=$(cut -f2 "$WORK/byhost.tsv" | sort -n | tail -1)
MAXBH=$(cut -f1 "$WORK/byhost.tsv" | sort -n | tail -1)
NHOST=$(wc -l < "$WORK/hosts.tsv" | tr -d ' ')
say "  max product id $MAXP (of $NPROD)   max target id $MAXW (of $NTARGET)   max host id $MAXH (of $NHOST)"
say "  byhost: max product $MAXBP, max host $MAXBH"
[ "$MAXP" -lt "$NPROD" ] || die "index references product $MAXP but only $NPROD exist"
[ "$MAXW" -lt "$NTARGET" ] || die "index references target $MAXW but only $NTARGET exist"
[ "$MAXBP" -lt "$NPROD" ] || die "byhost references product $MAXBP but only $NPROD exist"
[ "$MAXBH" -lt "$NHOST" ] || die "byhost references host $MAXBH but only $NHOST exist"
[ "$MAXH" -lt "$NHOST" ] || die "detail references host $MAXH but only $NHOST exist"
grep -q '""' "$OUT/index.json" && die "index.json contains an empty delta list"
say "  ok"

CORE=$(cat "$OUT/targets.json" "$OUT/products.json" "$OUT/index.json" "$OUT/situations.json" | gzip -c | wc -c | tr -d ' ')
say ""
say "  offline core (weeds+products+index+situations): $CORE bytes gzipped"
say "done."

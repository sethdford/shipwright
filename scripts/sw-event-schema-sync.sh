#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright event-schema sync — keep config/event-schema.json in step    ║
# ║  with the emit_event() call sites that actually exist in scripts/        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Why this exists:
#   lib/helpers.sh warns on stderr for every emit_event whose type is absent
#   from config/event-schema.json. The schema had drifted to 56 registered
#   types against 507 emitted, so most events printed
#     WARN: Unknown event type '<x>' — update config/event-schema.json
#   That noise is not harmless: several commands emit JSON on stdout, and any
#   caller that merges streams (`cmd 2>&1 | jq`) gets a warning line spliced
#   into the middle of the JSON. Hand-maintaining the list is what let it drift,
#   so this regenerates it instead.
#
# Usage:
#   bash scripts/sw-event-schema-sync.sh            # report drift, exit 1 if any
#   bash scripts/sw-event-schema-sync.sh --write    # rewrite the schema
#
# Only statically-analysable literal call sites are picked up:
#   emit_event "some.type" "key=value" ...
# Types built from a variable (emit_event "$type") cannot be resolved here and
# are reported so they can be registered by hand.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SCHEMA="${SCHEMA:-$REPO_DIR/config/event-schema.json}"

WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

WRITE="$WRITE" SCHEMA="$SCHEMA" REPO_DIR="$REPO_DIR" python3 - <<'PY'
import json, os, re, sys, pathlib, collections

schema_path = pathlib.Path(os.environ['SCHEMA'])
repo        = pathlib.Path(os.environ['REPO_DIR'])
write       = os.environ['WRITE'] == '1'

schema = json.loads(schema_path.read_text())
existing = schema.get('event_types', {})

# emit_event "type" "k=v" "k2=$v2" ... — capture the type and the literal keys.
CALL = re.compile(r'emit_event\s+"([a-zA-Z0-9_.\-]+)"((?:\s+"[^"]*")*)')
KEY  = re.compile(r'"([a-zA-Z_][a-zA-Z0-9_]*)=')
DYNAMIC = re.compile(r'emit_event\s+"\$')

fields  = collections.defaultdict(set)
dynamic = 0
for f in sorted(repo.glob('scripts/**/*.sh')):
    text = f.read_text()
    dynamic += len(DYNAMIC.findall(text))
    for etype, args in CALL.findall(text):
        fields[etype].update(KEY.findall(args))

emitted = set(fields)
known   = set(existing)
missing = sorted(emitted - known)
stale   = sorted(known - emitted)   # registered but no literal call site

print(f"  registered : {len(known)}")
print(f"  emitted    : {len(emitted)}")
print(f"  missing    : {len(missing)}")
print(f"  no-call-site: {len(stale)}  (kept — may be emitted via a variable)")
if dynamic:
    print(f"  note: {dynamic} emit_event call(s) use a variable type — not resolvable statically")

if not missing:
    print("\n  schema is in sync")
    sys.exit(0)

if not write:
    print("\n  missing types (first 15):")
    for m in missing[:15]:
        print(f"    {m}")
    if len(missing) > 15:
        print(f"    ... and {len(missing)-15} more")
    print("\n  run with --write to update")
    sys.exit(1)

for etype in missing:
    # Observed keys become `optional`; nothing is marked required, because a
    # literal call site only proves a field CAN appear, not that it must.
    existing[etype] = {"required": [], "optional": sorted(fields[etype])}

schema['event_types'] = dict(sorted(existing.items()))
schema_path.write_text(json.dumps(schema, indent=2) + "\n")
print(f"\n  wrote {len(missing)} new event types -> {schema_path.relative_to(repo)}")
PY

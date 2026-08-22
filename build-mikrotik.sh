#!/usr/bin/env bash
# Build the image for MikroTik RouterOS containers and export it as a tar file that can be
# uploaded to the router: Docker schema v2s2 manifest (not OCI), uncompressed layers.
#
# usage: ./build-mikrotik.sh <name:tag> [platform] [output.tar]
#   e.g. ./build-mikrotik.sh trungsky/tsproxy:2608221619 linux/amd64 tsproxy-amd64.tar
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${1:?usage: $0 <name:tag> [platform] [output.tar]}"
PLATFORM="${2:-linux/amd64}"
OUT="${3:-$(basename "${IMAGE%:*}")-${IMAGE##*:}.tar}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

docker buildx build --platform "$PLATFORM" --provenance=false --sbom=false -t "$IMAGE" --load .

# skopeo refuses to overwrite an existing docker-archive, so always write to a fresh file
skopeo copy --format v2s2 --dest-compress=false \
  "docker-daemon:$IMAGE" "docker-archive:$TMP/image.tar:$IMAGE"

# skopeo always writes the fully-qualified name (docker.io/...) into RepoTags and RouterOS shows
# it verbatim, so rewrite manifest.json and repositories with the name exactly as given
python3 - "$TMP/image.tar" "$OUT" "$IMAGE" <<'PY'
import io, json, sys, tarfile

src, dst, image = sys.argv[1:]
name = image.rsplit(':', 1)[0]

with tarfile.open(src) as tin, tarfile.open(dst, 'w', format=tarfile.USTAR_FORMAT) as tout:
    for m in tin:
        f = tin.extractfile(m) if m.isfile() else None
        if m.name in ('manifest.json', 'repositories'):
            obj = json.load(f)
            if m.name == 'manifest.json':
                for entry in obj:
                    entry['RepoTags'] = [image]
            else:
                tags = {}
                for v in obj.values():
                    tags.update(v)
                obj = {name: tags}
            data = json.dumps(obj, separators=(',', ':')).encode()
            m.size = len(data)
            f = io.BytesIO(data)
        elif f is not None:
            if f.read(2) == b'\x1f\x8b':
                sys.exit(f'ERROR: layer {m.name} is gzip-compressed')
            f.seek(0)
        tout.addfile(m, f)
PY

echo
echo "== $OUT"
tar xOf "$OUT" manifest.json
echo
skopeo inspect "docker-archive:$OUT" | grep -E '"(Architecture|Os|Created)"'

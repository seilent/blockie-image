set positional-arguments

podman := env_var_or_default("PODMAN", "podman")

pkg name:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ ! -f packages/$1/LICENSE ]] || cmp -s "packages/$1/LICENSE" LICENSE || { echo "packages/$1/LICENSE differs from LICENSE" >&2; exit 1; }
    hash=$(build/pkg-hash.sh "$1")
    mapfile -t inputs < <(build/pkg-hash.sh --inputs "$1")
    dirty=0
    [[ -z $(git status --porcelain -- "${inputs[@]}") ]] || dirty=1
    out=out/pkg/$1
    tag=localhost/blockie-pkg/$1:$hash
    sel=$(PODMAN="{{podman}}" build/pkg-builder.sh build "$1")
    img=${sel% *}
    rm -rf "${out:?}"
    mkdir -p "$out"
    src=()
    if [[ -n ${PKG_INPUT:-} ]]; then
      src=(-v "$(realpath "$PKG_INPUT"):/input:ro,Z")
    fi
    epoch=$(git log -1 --format=%ct -- "packages/$1")
    [[ -n $epoch ]] || epoch=$(git log -1 --format=%ct)
    {{podman}} run --rm --memory=14g --cpus=6 --network=none "${src[@]}" -e "SOURCE_DATE_EPOCH=$epoch" \
      -v "$PWD/packages/$1:/src:ro,Z" \
      -v "$PWD/$out:/out:Z" \
      "$img" /src/build.sh /out
    if [[ -f tests/pkg-$1.sh ]]; then
      {{podman}} run --rm --memory=14g --cpus=6 --network=none \
        -v "$PWD/tests:/tests:ro,Z" \
        -v "$PWD/$out:/out:ro,Z" \
        "$img" "/tests/pkg-$1.sh" /out
    fi
    [[ ! -e $out/dirty ]] || dirty=1
    {{podman}} build --platform linux/arm64 --timestamp "$epoch" --memory=14g --cpu-period=100000 --cpu-quota=600000 -f build/pkg-wrap.Containerfile --label "blockie.dirty=$dirty" -t "$tag" "$out"
    echo "$tag"

pkg-push name:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t inputs < <(build/pkg-hash.sh --inputs "$1")
    if [[ -n $(git status --porcelain -- "${inputs[@]}") ]]; then
      echo "uncommitted changes in the inputs of $1" >&2
      exit 1
    fi
    hash=$(build/pkg-hash.sh "$1")
    local=localhost/blockie-pkg/$1:$hash
    if [[ $({{podman}} inspect -f '{{{{index .Labels "blockie.dirty"}}' "$local") != 0 ]]; then
      echo "$local was built from uncommitted inputs" >&2
      exit 1
    fi
    pass=out/audit/$1.pass
    [[ -s $pass ]] || { echo "$pass missing: run the package audit first" >&2; exit 1; }
    work=$(mktemp -d)
    trap 'rm -rf "${work:?}"' EXIT
    ctr=$({{podman}} create "$local" none)
    {{podman}} cp "$ctr:/rpms/." "$work/"
    {{podman}} rm "$ctr" > /dev/null
    found=0
    for f in "$work"/*.rpm; do
      [[ -f $f ]] || continue
      found=1
      grep -qxF "$(sha256sum < "$f" | cut -d' ' -f1)  ${f##*/}" "$pass" || { echo "${f##*/} in $local is not in $pass" >&2; exit 1; }
    done
    (( found )) || { echo "$local has no RPMs" >&2; exit 1; }
    src=()
    if [[ -n $(git ls-files -- "packages/$1/SOURCE.sha256") ]]; then
      : "${PKG_SOURCE:?packages/$1/SOURCE.sha256 pins a source: set PKG_SOURCE to its directory}"
      root=$PWD
      (cd "$PKG_SOURCE" && sha256sum --quiet -c "$root/packages/$1/SOURCE.sha256")
      mapfile -t src < <(awk '{ print $2 }' "packages/$1/SOURCE.sha256")
      oras=$(command -v "${ORAS:-$HOME/.local/bin/oras-v1.3.4}") || { echo "no oras: set ORAS" >&2; exit 1; }
      [[ $(sha256sum < "$oras" | cut -d' ' -f1) == 246c47e91bf2749a555ffe00a9824844c6df3a26d61974e3ce08f2077d79c556 ]] ||
        { echo "$oras is not the pinned oras 1.3.4" >&2; exit 1; }
    fi
    repo=ghcr.io/seilent/blockie/pkg/$1
    api=/user/packages/container/blockie%2Fpkg%2F$1
    keys=${BLOCKIE_KEYS:-$HOME/keystores/blockie-cosign}
    cosign=$(command -v "${COSIGN:-$HOME/.local/bin/cosign-v2.6.3}") || { echo "no cosign: set COSIGN" >&2; exit 1; }
    [[ $(sha256sum < "$cosign" | cut -d' ' -f1) == 7c78a7f2efc00088bd788a758db6e0928e79f3e0eb83eb5d3c499ed98da4c4f4 ]] ||
      { echo "$cosign is not the pinned cosign 2.6.3" >&2; exit 1; }
    {{podman}} login --get-login ghcr.io > /dev/null
    if ! gh api "$api" > /dev/null 2>&1; then
      start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      gh workflow run package-init.yml -R seilent/blockie-image -f name="$1"
      run=
      for _ in $(seq 60); do
        sleep 5
        run=$(gh run list -R seilent/blockie-image --workflow package-init.yml --event workflow_dispatch \
          --user seilent --json databaseId,createdAt \
          --jq "[.[] | select(.createdAt >= \"$start\")][0].databaseId // empty")
        [[ -z $run ]] || break
      done
      [[ -n $run ]] || { echo "package-init run not found" >&2; exit 1; }
      gh run watch "$run" -R seilent/blockie-image --exit-status > /dev/null
    fi
    if err=$(skopeo inspect --raw "docker://$repo:$hash" 2>&1 > /dev/null); then
      echo "$repo:$hash exists" >&2
      exit 1
    fi
    if ! grep -qiE 'manifest unknown|404' <<< "$err"; then
      echo "$err" >&2
      exit 1
    fi
    {{podman}} tag "$local" "$repo:$hash"
    digest=$work/digest
    {{podman}} push --digestfile "$digest" "$repo:$hash"
    if (( ${#src[@]} )); then
      kind=application/vnd.blockie.source.v1
      art=$(cd "$PKG_SOURCE" && "$oras" attach --artifact-type "$kind" --format go-template --template '{{{{.digest}}' \
        "$repo@$(cat "$digest")" "${src[@]}")
      [[ $art =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no source referrer digest from oras attach: $art" >&2; exit 1; }
      "$oras" discover --artifact-type "$kind" --format json "$repo@$(cat "$digest")" |
        jq -e --arg d "$art" '[.referrers[].digest] | index($d) != null' > /dev/null ||
        { echo "$repo@$art is not a source referrer of $repo@$(cat "$digest")" >&2; exit 1; }
      COSIGN_PASSWORD=$(cat "$keys/blockie.password") \
        "$cosign" sign -y --new-bundle-format=false --key "$keys/blockie.key" "$repo@$art"
      "$cosign" verify --key system_files/usr/share/blockie/keys/blockie.pub "$repo@$art" > /dev/null
    fi
    COSIGN_PASSWORD=$(cat "$keys/blockie.password") \
      "$cosign" sign -y --new-bundle-format=false --key "$keys/blockie.key" "$repo@$(cat "$digest")"
    "$cosign" verify --key system_files/usr/share/blockie/keys/blockie.pub "$repo@$(cat "$digest")" > /dev/null
    init=$(gh api "$api/versions" --jq '.[] | select(.metadata.container.tags | index("init")) | .id')
    if [[ -n $init ]]; then
      gh api -X DELETE "$api/versions/$init"
    fi
    echo "$repo:$hash"

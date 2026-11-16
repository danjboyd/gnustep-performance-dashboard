#!/usr/bin/env bash
# Future hosted workflow only. Static tests never execute Docker/build phases.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'CSD driver requires the explicit hosted CI environment' >&2; exit 1; }
pd_repo="$(git rev-parse --show-toplevel)"
pd_work="$pd_repo/out/csd-ci"
pd_builder="$pd_work/builder"
pd_state="$pd_work/container-inputs.json"
pd_policy="$pd_repo/.github/scripts/csd-review-state.py"
python3 "$pd_repo/.github/scripts/release-selection.py" --custom-mode "${CSD_MODE:-review}" --version "${CSD_VERSION:-}" >/dev/null
[[ "$(git -C "$pd_builder" rev-parse HEAD)" == 4d5504bbedf076f824c952f4ab198d09547c8c3c ]]
python3 "$pd_repo/scripts/check-csd-package.py" review-inputs "$pd_repo/packaging/linux/v017-review-inputs.json"
python3 "$pd_policy" builder-check --root "$pd_repo" --builder "$pd_builder"
mkdir -p "$pd_work/logs"
case "${1:-}" in
  prepare)
    # Capture the resolved base and package inventory before the first compiler.
    docker pull debian:13 >"$pd_work/logs/base-image.log" 2>&1
    pd_base="$(docker image inspect debian:13 --format '{{index .RepoDigests 0}}')"
    sed "s|^FROM debian:13$|FROM $pd_base|" "$pd_builder/toolchains/linux-amd64-clang/Dockerfile" > "$pd_work/sdk-pinned.Dockerfile"
    docker build -f "$pd_work/sdk-pinned.Dockerfile" -t pd-csd-sdk-base "$pd_builder/toolchains/linux-amd64-clang" >"$pd_work/logs/sdk-image.log" 2>&1
    docker build --build-arg SDK_BASE=pd-csd-sdk-base --build-arg CI_UID="$(id -u)" --build-arg CI_GID="$(id -g)" \
      -f "$pd_repo/.github/containers/csd-review.Dockerfile" -t pd-csd-review "$pd_repo" >"$pd_work/logs/review-image.log" 2>&1
    pd_image="$(docker image inspect pd-csd-review --format '{{.Id}}')"
    docker run --rm "$pd_image" dpkg-query -W '-f=${binary:Package}\t${Version}\n' >"$pd_work/package-inventory.txt"
    pd_base="$(docker image inspect debian:13 --format '{{index .RepoDigests 0}}')"
    python3 "$pd_policy" fingerprint --root "$pd_repo" --builder "$pd_builder" \
      --inventory "$pd_work/package-inventory.txt" --base-digest "$pd_base" --image-id "$pd_image" \
      --uid "$(id -u)" --gid "$(id -g)" --output "$pd_state"
    pd_key="$(python3 "$pd_policy" cache-key --root "$pd_repo" --state "$pd_state")"
    echo "cache_key=$pd_key" >> "$GITHUB_OUTPUT"
    ;;
  sdk|review)
    # Build and run the application only in the matching Debian13 image.
    pd_image="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reviewImageID"])' "$pd_state")"
    [[ "$pd_image" =~ ^sha256:[0-9a-f]{64}$ ]]
    docker run --rm -v "$pd_repo:$pd_repo" -w "$pd_repo" \
      -e GITHUB_ACTIONS=true -e CSD_VERSION -e CSD_MODE -e SDK_CACHE_HIT \
      "$pd_image" bash "$pd_repo/.github/scripts/csd-review-container.sh" "$1"
    ;;
  *) echo 'usage: csd-review-host.sh prepare|sdk|review' >&2; exit 2 ;;
esac

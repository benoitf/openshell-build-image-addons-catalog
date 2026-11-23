#!/usr/bin/env bash
#
# Copyright (C) 2026 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Regenerates addons.json from the upstream addons repository and the images
# published on the registry. Curated fields (displayName, description, icon)
# are kept; new addons get placeholder values to fill in.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-openkaiden/openshell-build-image-addons}"
REGISTRY="${REGISTRY:-ghcr.io/openkaiden}"
CATALOG="${CATALOG:-static/api/addons.json}"
LIBC_ANNOTATION=ai.openkaiden.openshell-build-image.libc

# Prints the tool version packaged by the addon whose files are in directory $1:
# the first lowercase `*version=` default in install.sh (`x="${X_VERSION:-1.2.3}"`
# or `default_x_version=1.2.3`), else the tag in a pinned-image comment of a
# Containerfile (`# docker.io/library/node:24.22.3-bookworm-slim`), else "unknown".
extract_version() {
  local dir="$1" line version=""
  if [[ -f "${dir}/install.sh" ]]; then
    line=$(grep -E '^[a-z_]*version=' "${dir}/install.sh" | head -n 1 || true)
    if [[ -n "$line" ]]; then
      version="${line#*=}"
      [[ "$version" == *':-'* ]] && version="${version#*:-}" && version="${version%%\}*}"
      version="${version//\"/}"
      version="${version//\'/}"
    fi
  fi
  if [[ -z "$version" ]]; then
    version=$(cat "${dir}"/Containerfile* 2>/dev/null |
      sed -nE 's/^#[[:space:]]*[^[:space:]]+:v?([0-9]+(\.[0-9]+)+).*/\1/p' | head -n 1)
  fi
  version="${version#v}"
  echo "${version:-unknown}"
}

sha256_digest() {
  echo "sha256:$(shasum -a 256 | cut -d ' ' -f 1)"
}

# Prints the digest of the manifest (index) behind an image reference.
manifest_digest() {
  skopeo inspect --raw "docker://$1" | sha256_digest
}

# Prints the commit tag of $1 whose digest is $2, trying $3 (previous commit) first.
find_commit() {
  local image="$1" digest="$2" previous="$3" tag
  for tag in $previous $(skopeo list-tags "docker://${image}" |
    jq -r '.Tags[] | select(test("^[0-9a-f]{40}$"))'); do
    if [[ "$(manifest_digest "${image}:${tag}")" == "$digest" ]]; then
      echo "$tag"
      return 0
    fi
  done
  return 1
}

main() {
  local src old gen addon_dir category name image raw digest commit libc
  local files version previous
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  src="${work}/src"
  git clone --quiet --filter=blob:none "https://github.com/${UPSTREAM_REPO}.git" "$src"

  if [[ -f "$CATALOG" ]]; then old=$(cat "$CATALOG"); else old='{"addons":[]}'; fi
  gen='[]'

  for addon_dir in "$src"/addons/*/*/; do
    addon_dir="${addon_dir%/}"
    name="${addon_dir##*/}"
    category="${addon_dir%/*}"
    category="${category##*/}"
    image="${REGISTRY}/${UPSTREAM_REPO##*/}-${name}"
    previous=$(jq -r --arg n "$name" '.addons[] | select(.name == $n) | .commit' <<< "$old")

    # Hash the raw bytes from a file: command substitution would alter them.
    raw="${work}/${name}.json"
    if ! skopeo inspect --raw "docker://${image}:next" > "$raw" 2>/dev/null; then
      echo "::notice::${category}/${name}: ${image}:next is not published, skipping"
      continue
    fi
    digest=$(sha256_digest < "$raw")
    libc=$(jq -c --arg a "$LIBC_ANNOTATION" \
      '[.manifests[].annotations[$a] // empty] | unique' "$raw")

    if ! commit=$(find_commit "$image" "$digest" "$previous"); then
      echo "::warning::${category}/${name}: no commit tag matches ${image}:next, keeping previous entry"
      gen=$(jq -c --arg n "$name" --argjson old "$old" \
        '. + [$old.addons[] | select(.name == $n)]' <<< "$gen")
      continue
    fi

    files="${work}/${name}"
    mkdir -p "$files"
    git -C "$src" ls-tree --name-only "${commit}:addons/${category}/${name}" |
      while IFS= read -r f; do
        git -C "$src" show "${commit}:addons/${category}/${name}/${f}" > "${files}/${f}"
      done
    version=$(extract_version "$files")

    echo "${category}/${name}: ${version} (${commit:0:7})"
    gen=$(jq -c \
      --arg name "$name" --arg category "$category" --arg version "$version" \
      --arg commit "$commit" --arg image "${image}@${digest}" --argjson libc "$libc" \
      '. + [{name: $name, category: $category, version: $version,
             commit: $commit, image: $image, libc: $libc}]' <<< "$gen")
  done

  jq --argjson gen "$gen" '
    (.addons | map({key: .name, value: .}) | from_entries) as $old |
    {addons: ($gen | map(
      . as $g |
      ($old[$g.name] // {displayName: $g.name, description: "TODO", icon: null}) as $o |
      {name: $g.name, displayName: $o.displayName, category: $g.category,
       description: $o.description, icon: $o.icon, version: $g.version,
       commit: $g.commit, image: $g.image, libc: $g.libc}
    ) | sort_by(.category, .name))}
  ' <<< "$old" > "${work}/addons.json"
  mv "${work}/addons.json" "$CATALOG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

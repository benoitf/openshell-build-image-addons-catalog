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

# Validates addons.json: schema, curated fields, icons, ordering, and that every
# image exists on the registry with the expected libc variants and commit tag.

set -uo pipefail

CATALOG="${CATALOG:-static/api/addons.json}"
LIBC_ANNOTATION=ai.openkaiden.openshell-build-image.libc
errors=0

error() {
  echo "::error::$*"
  errors=$((errors + 1))
}

if ! jq -e '.addons | type == "array"' "$CATALOG" > /dev/null 2>&1; then
  error "${CATALOG} is not valid JSON with a top-level addons array"
  exit 1
fi

# Static checks; each output line is one problem.
problems=$(jq -r '
  def str: type == "string" and length > 0;
  (.addons | to_entries[] | .key as $i | .value as $a | ($a.name // "#\($i)") as $n |
    (["name", "displayName", "category", "description", "version", "commit", "image"][] |
      select(($a[.] | str) | not) | "\($n): \(.) must be a non-empty string"),
    (select(($a.icon == null or ($a.icon | str)) | not) |
      "\($n): icon must be a path or null"),
    (select(($a.libc | type == "array" and all(.[]; type == "string")) | not) |
      "\($n): libc must be an array of strings"),
    (select($a.description == "TODO") | "\($n): description is TODO, curate it"),
    (select(($a.category | str) and ($a.category | test("^[a-z0-9][a-z0-9-]*$") | not)) |
      "\($n): category must be a lowercase slug"),
    (select(($a.commit | str) and ($a.commit | test("^[0-9a-f]{40}$") | not)) |
      "\($n): commit must be a 40-character hex SHA"),
    (select(($a.image | str) and
            ($a.image | test("^ghcr\\.io/[^@]+-" + $n + "@sha256:[0-9a-f]{64}$") | not)) |
      "\($n): image must be ghcr.io/<owner>/<repository>-\($n)@sha256:<digest>")),
  ([.addons[].name] | group_by(.)[] | select(length > 1) | "duplicate addon name: \(.[0])"),
  (select(.addons != (.addons | sort_by(.category, .name))) |
    "addons must be sorted by category, then name")
' "$CATALOG")
while IFS= read -r p; do
  [[ -n "$p" ]] && error "$p"
done <<< "$problems"

# Fields are separated by \x1f: tab separators would collapse empty fields.
while IFS=$'\x1f' read -r name icon image commit libc; do
  if [[ -n "$icon" ]]; then
    if [[ ! -f "$(dirname "$CATALOG")/${icon}" ]]; then
      error "${name}: icon ${icon} does not exist"
    elif ! head -c 512 "$(dirname "$CATALOG")/${icon}" | grep -q '<svg'; then
      error "${name}: icon ${icon} is not an SVG"
    fi
  fi

  raw=$(mktemp)
  if ! skopeo inspect --raw "docker://${image}" > "$raw" 2> /dev/null; then
    error "${name}: image ${image} not found"
    rm -f "$raw"
    continue
  fi
  if ! jq -e '.mediaType == "application/vnd.oci.image.index.v1+json"' "$raw" > /dev/null; then
    error "${name}: ${image} is not an OCI image index"
  fi
  actual_libc=$(jq -c --arg a "$LIBC_ANNOTATION" \
    '[.manifests[].annotations[$a] // empty] | unique' "$raw")
  if [[ "$actual_libc" != "$libc" ]]; then
    error "${name}: libc is ${libc} but the image index has ${actual_libc}"
  fi
  rm -f "$raw"

  tag_digest=$(skopeo inspect --raw "docker://${image%@*}:${commit}" 2> /dev/null |
    shasum -a 256 | cut -d ' ' -f 1)
  if [[ "sha256:${tag_digest}" != "${image#*@}" ]]; then
    error "${name}: tag ${commit} does not point to ${image#*@}"
  fi
done < <(jq -r '.addons[] | select(.image | type == "string") |
  [.name, (.icon // ""), .image, (.commit // ""), (.libc | tojson)] | join("\u001f")' "$CATALOG")

if (( errors > 0 )); then
  echo "${errors} problem(s) found in ${CATALOG}"
  exit 1
fi
echo "${CATALOG}: $(jq '.addons | length' "$CATALOG") addons OK"

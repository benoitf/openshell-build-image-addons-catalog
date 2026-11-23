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

# Checks extract_version against the version patterns used by upstream addons.

set -euo pipefail

source "$(dirname "$0")/update-addons.sh"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
failures=0

check() {
  local expected="$1" got
  got=$(extract_version "$dir")
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: expected '$expected', got '$got'"
    failures=$((failures + 1))
  fi
  rm -f "$dir"/*
}

printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
  '# CODEX_VERSION must stay in range' \
  'codex_version="${CODEX_VERSION:-0.159.3}"' \
  'codex_acp_version="${CODEX_ACP_VERSION:-v2.1.1}"' > "$dir/install.sh"
check 0.159.3

printf '%s\n' 'default_git_version=2.56.1' \
  'git_version="${GIT_VERSION:-${default_git_version}}"' 'curl_version=8.23.0' > "$dir/install.sh"
check 2.56.1

printf '%s\n' 'tool_version="${TOOL_VERSION:-v1.4.0}"' > "$dir/install.sh"
check 1.4.0

printf '%s\n' 'set -eu' 'cp -RP /usr/local/bin/node /tmp/rootfs/' > "$dir/install.sh"
printf '%s\n' '# docker.io/library/node:24.22.3-bookworm-slim' \
  'FROM docker.io/library/node@sha256:dc26ae92 AS builder' > "$dir/Containerfile.glibc"
check 24.22.3

printf '%s\n' 'FROM alpine' > "$dir/Containerfile"
check unknown

if (( failures > 0 )); then
  exit 1
fi
echo "extract_version: all checks passed"

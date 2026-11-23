<!--

Copyright (C) 2026 Red Hat, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

SPDX-License-Identifier: Apache-2.0
-->

# OpenShell build image addons catalog

[`static/api/addons.json`](static/api/addons.json) lists the addons built by
[openshell-build-image-addons](https://github.com/openkaiden/openshell-build-image-addons),
with their category, version, description, icon and a digest-pinned OCI image.

## Consuming the catalog

Fetch the raw file from the `main` branch:

```sh
curl -fsSL https://raw.githubusercontent.com/benoitf/openshell-build-image-addons-catalog/main/static/api/addons.json |
  jq -r '.addons[] | [.category, .name, .version, .image] | @tsv'
```

Each `image` is an OCI index with `linux/amd64` and `linux/arm64` images, and with
one image per libc when `libc` is not empty. Select the descriptor that matches your
base image and copy its files:

```Dockerfile
COPY --from=ghcr.io/openkaiden/openshell-build-image-addons-git@sha256:<descriptor digest> / /
```

See the upstream
[README](https://github.com/openkaiden/openshell-build-image-addons#inspect-the-published-index)
for how to select a descriptor and which `ENV` settings to carry over.

## Format

```json
{
  "addons": [
    {
      "name": "git",
      "displayName": "Git",
      "category": "devtools",
      "description": "Statically linked Git with HTTPS support...",
      "icon": "icons/git.svg",
      "version": "2.56.1",
      "commit": "a5cabd14808ec154e5e45166496cd3ec19c516cd",
      "image": "ghcr.io/openkaiden/openshell-build-image-addons-git@sha256:...",
      "libc": []
    }
  ]
}
```

| Field | Type | Source | Meaning |
| --- | --- | --- | --- |
| `name` | string | generated | Addon directory name, unique across categories |
| `displayName` | string | curated | Human-readable name |
| `category` | string | generated | Parent directory upstream: `agents`, `devtools`, `runtimes`, ... |
| `description` | string | curated | One-sentence description |
| `icon` | string or null | curated | SVG path relative to `addons.json` (files live in `static/api/icons/`) |
| `version` | string | generated | Packaged tool version from the addon's `install.sh` or Containerfile, or `unknown` |
| `commit` | string | generated | Upstream commit that built the image (also an image tag) |
| `image` | string | generated | Image index currently tagged `next`, pinned by digest |
| `libc` | string[] | generated | libc variants in the index; empty means libc-independent |

Entries are sorted by category, then name.

## How updates work

The [update-addons](.github/workflows/update-addons.yaml) workflow runs daily and on
manual dispatch. [`.github/scripts/update-addons.sh`](.github/scripts/update-addons.sh):

1. Discovers `addons/<category>/<addon>/` in the upstream repository.
2. Resolves `ghcr.io/openkaiden/openshell-build-image-addons-<addon>:next` to its
   digest and finds the commit tag that points to the same digest.
3. Reads the tool version from the addon's files at that commit.
4. Rewrites `static/api/addons.json`, keeping curated fields. It adds new addons with a `TODO`
   description and drops addons that were removed upstream.

When anything changes, it opens or updates a pull request from the `update-addons`
branch.

PRs opened with the default `GITHUB_TOKEN` do not trigger other workflows. Set a
`CATALOG_PR_TOKEN` secret (a PAT or GitHub App token) so `pr-check` runs on them.
Also enable "Allow GitHub Actions to create and approve pull requests" in the
repository's Actions settings.

[pr-check](.github/workflows/pr-check.yaml) runs
[`.github/scripts/check-addons.sh`](.github/scripts/check-addons.sh) on every pull request. It
validates the JSON structure and field formats, rejects `TODO` descriptions,
duplicate names and wrong ordering, and checks that each icon exists. It also checks
that each image exists as an OCI index, that its libc variants match, and that its
commit tag resolves to the same digest.

## Contributing

When the update PR adds an addon, edit its entry in `static/api/addons.json`. Set
`displayName` and `description`, and add `static/api/icons/<name>.svg` (or leave `icon` as
`null`). Then push to the PR branch.

To run everything locally, you need `bash`, `git`, `jq`, `skopeo` and `shasum`:

```sh
.github/scripts/test-extract-version.sh   # unit check for version extraction
.github/scripts/update-addons.sh          # regenerate static/api/addons.json
.github/scripts/check-addons.sh           # validate static/api/addons.json and the images
```

Icons come from [Simple Icons](https://simpleicons.org) (CC0-1.0).

## License

[Apache-2.0](LICENSE)

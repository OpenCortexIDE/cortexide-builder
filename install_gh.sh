#!/usr/bin/env bash

set -ex

GH_ARCH="amd64"

# Fetch latest release with error handling
# Use GITHUB_TOKEN if available for authenticated requests (higher rate limit)
if [[ -n "${GITHUB_TOKEN}" ]]; then
  echo "Using GITHUB_TOKEN for authenticated GitHub API request"
  API_RESPONSE=$( curl --retry 12 --retry-delay 30 -sSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/cli/cli/releases/latest" )
else
  echo "Warning: GITHUB_TOKEN not set, using unauthenticated request (lower rate limit)"
  API_RESPONSE=$( curl --retry 12 --retry-delay 30 -sSL "https://api.github.com/repos/cli/cli/releases/latest" )
fi

# Check if API response is valid JSON and contains tag_name
if ! echo "${API_RESPONSE}" | jq -e '.tag_name' > /dev/null 2>&1; then
  echo "Error: Failed to fetch GitHub CLI release information"
  echo "API Response: ${API_RESPONSE}"
  exit 1
fi

TAG=$( echo "${API_RESPONSE}" | jq --raw-output '.tag_name' )

# Validate tag is not null or empty
if [[ -z "${TAG}" || "${TAG}" == "null" ]]; then
  echo "Error: Invalid tag_name received from GitHub API: ${TAG}"
  echo "Full API Response: ${API_RESPONSE}"
  exit 1
fi

VERSION=${TAG#v}

# Validate version is not empty
if [[ -z "${VERSION}" ]]; then
  echo "Error: Empty version after processing tag: ${TAG}"
  exit 1
fi

echo "Installing GitHub CLI version ${VERSION} (tag: ${TAG})"

curl --retry 12 --retry-delay 120 -sSL "https://github.com/cli/cli/releases/download/${TAG}/gh_${VERSION}_linux_${GH_ARCH}.tar.gz" -o "gh_${VERSION}_linux_${GH_ARCH}.tar.gz"

# Verify the downloaded file is a valid tar.gz
if ! tar -tzf "gh_${VERSION}_linux_${GH_ARCH}.tar.gz" > /dev/null 2>&1; then
  echo "Error: Downloaded file is not a valid tar.gz archive"
  echo "File size: $(stat -c%s "gh_${VERSION}_linux_${GH_ARCH}.tar.gz" 2>/dev/null || echo "unknown")"
  exit 1
fi

tar xf "gh_${VERSION}_linux_${GH_ARCH}.tar.gz"

# Verify the binary exists before copying
if [[ ! -f "gh_${VERSION}_linux_${GH_ARCH}/bin/gh" ]]; then
  echo "Error: GitHub CLI binary not found in extracted archive"
  exit 1
fi

cp "gh_${VERSION}_linux_${GH_ARCH}/bin/gh" /usr/local/bin/

# Verify installation
if ! gh --version > /dev/null 2>&1; then
  echo "Error: GitHub CLI installation verification failed"
  exit 1
fi

gh --version

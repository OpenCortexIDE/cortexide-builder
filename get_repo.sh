#!/usr/bin/env bash
# shellcheck disable=SC2129

set -e

# Echo all environment variables used by this script
echo "----------- get_repo -----------"
echo "Environment variables:"
echo "CI_BUILD=${CI_BUILD}"
echo "GITHUB_REPOSITORY=${GITHUB_REPOSITORY}"
echo "RELEASE_VERSION=${RELEASE_VERSION}"
echo "VSCODE_LATEST=${VSCODE_LATEST}"
echo "VSCODE_QUALITY=${VSCODE_QUALITY}"
echo "GITHUB_ENV=${GITHUB_ENV}"

echo "SHOULD_DEPLOY=${SHOULD_DEPLOY}"
echo "SHOULD_BUILD=${SHOULD_BUILD}"
echo "-------------------------"

# git workaround
if [[ "${CI_BUILD}" != "no" ]]; then
  git config --global --add safe.directory "/__w/$( echo "${GITHUB_REPOSITORY}" | awk '{print tolower($0)}' )"
fi

# Check if local CortexIDE repo exists
CORTEXIDE_REPO="../cortexide"
if [[ -d "${CORTEXIDE_REPO}" && -f "${CORTEXIDE_REPO}/package.json" ]]; then
  echo "Using local CortexIDE repository at ${CORTEXIDE_REPO}..."
  
  # Remove existing vscode directory if it exists
  rm -rf vscode
  
  # Copy the local CortexIDE repo to vscode directory (exclude heavy/temp files)
  echo "Copying CortexIDE repository to vscode directory..."
  mkdir -p vscode
  rsync -a --delete \
    --exclude ".git" \
    --exclude "node_modules" \
    --exclude "out" \
    --exclude ".build" \
    --exclude ".vscode" \
    --exclude "**/.vscode" \
    --exclude "**/node_modules" \
    "${CORTEXIDE_REPO}/" "vscode/"
  
  cd vscode || { echo "'vscode' dir not found"; exit 1; }
  
  # Get version info from local repo
  MS_TAG=$( jq -r '.version' "package.json" 2>/dev/null || echo "" )
  MS_COMMIT=$( git rev-parse HEAD 2>/dev/null || echo "local" )
  
  # CRITICAL: Validate MS_TAG is not empty
  if [[ -z "${MS_TAG}" || "${MS_TAG}" == "null" ]]; then
    echo "Error: Could not read version from package.json. MS_TAG is empty." >&2
    echo "package.json path: $(pwd)/package.json" >&2
    if [[ -f "package.json" ]]; then
      echo "package.json contents:" >&2
      cat package.json | head -20 >&2
    fi
    exit 1
  fi
  
  # Check for CortexIDE version fields (cortexVersion/cortexRelease) or fallback to voidVersion/voidRelease
  if jq -e '.cortexVersion' product.json > /dev/null 2>&1; then
    CORTEX_VERSION=$( jq -r '.cortexVersion' "product.json" )
    CORTEX_RELEASE=$( jq -r '.cortexRelease' "product.json" )
  elif jq -e '.voidVersion' product.json > /dev/null 2>&1; then
    CORTEX_VERSION=$( jq -r '.voidVersion' "product.json" )
    CORTEX_RELEASE=$( jq -r '.voidRelease' "product.json" )
  else
    CORTEX_VERSION="${MS_TAG}"
    CORTEX_RELEASE="0000"
  fi
  
  # Allow override via environment variable
  if [[ -n "${CORTEXIDE_RELEASE}" ]]; then
    CORTEX_RELEASE="${CORTEXIDE_RELEASE}"
  fi
  
  if [[ -n "${CORTEX_RELEASE}" ]]; then
    RELEASE_VERSION="${MS_TAG}${CORTEX_RELEASE}"
  else
    RELEASE_VERSION="${MS_TAG}0000"
  fi
  
  # CRITICAL: Validate RELEASE_VERSION is not empty
  if [[ -z "${RELEASE_VERSION}" ]]; then
    echo "Error: RELEASE_VERSION is empty. MS_TAG='${MS_TAG}', CORTEX_RELEASE='${CORTEX_RELEASE}'" >&2
    exit 1
  fi
else
  # Fallback to cloning from GitHub (for CI or if local repo not found)
  CORTEXIDE_BRANCH="main"
  echo "Local CortexIDE repo not found, cloning from GitHub ${CORTEXIDE_BRANCH}..."
  
  mkdir -p vscode
  cd vscode || { echo "'vscode' dir not found"; exit 1; }
  
  # Remove any files that might conflict with checkout (e.g., build artifacts in .gitignore)
  # This handles cases where files exist from previous runs
  if [[ -f "build/win32/code.iss" ]]; then
    echo "Removing conflicting file: build/win32/code.iss"
    rm -f "build/win32/code.iss"
  fi
  
  git init -q
  
  # Use GITHUB_TOKEN if available for authentication (GitHub Actions provides this automatically)
  # Otherwise use the public URL
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    echo "Using GITHUB_TOKEN for authentication"
    git remote add origin "https://${GITHUB_TOKEN}@github.com/OpenCortexIDE/cortexide.git"
  else
    git remote add origin https://github.com/OpenCortexIDE/cortexide.git
  fi
  
  # Allow callers to specify a particular commit to checkout via the
  # environment variable CORTEXIDE_COMMIT.  We still default to the tip of the
  # ${CORTEXIDE_BRANCH} branch when the variable is not provided.
  if [[ -n "${CORTEXIDE_COMMIT}" ]]; then
    echo "Using explicit commit ${CORTEXIDE_COMMIT}"
    # Fetch just that commit to keep the clone shallow.
    git fetch --depth 1 origin "${CORTEXIDE_COMMIT}"
    # Remove any conflicting untracked files before checkout
    # This handles cases where files in .gitignore exist in the working directory
    git clean -fd 2>/dev/null || true
    git checkout -f "${CORTEXIDE_COMMIT}" 2>&1 || {
      # If checkout fails due to untracked files, remove them and try again
      echo "Checkout failed, cleaning up conflicting files..."
      git status --porcelain | grep '^??' | awk '{print $2}' | xargs rm -rf 2>/dev/null || true
      git checkout -f "${CORTEXIDE_COMMIT}"
    }
  else
    git fetch --depth 1 origin "${CORTEXIDE_BRANCH}"
    # Remove any conflicting untracked files before checkout
    # This handles cases where files in .gitignore exist in the working directory
    git clean -fd 2>/dev/null || true
    git checkout -f FETCH_HEAD 2>&1 || {
      # If checkout fails due to untracked files, remove them and try again
      echo "Checkout failed, cleaning up conflicting files..."
      git status --porcelain | grep '^??' | awk '{print $2}' | xargs rm -rf 2>/dev/null || true
      git checkout -f FETCH_HEAD
    }
  fi
  
  MS_TAG=$( jq -r '.version' "package.json" 2>/dev/null || echo "" )
  MS_COMMIT=$CORTEXIDE_BRANCH
  
  # CRITICAL: Validate MS_TAG is not empty
  if [[ -z "${MS_TAG}" || "${MS_TAG}" == "null" ]]; then
    echo "Error: Could not read version from package.json. MS_TAG is empty." >&2
    echo "package.json path: $(pwd)/package.json" >&2
    if [[ -f "package.json" ]]; then
      echo "package.json contents:" >&2
      cat package.json | head -20 >&2
    fi
    exit 1
  fi
  
  # Check for CortexIDE version fields or fallback
  if jq -e '.cortexVersion' product.json > /dev/null 2>&1; then
    CORTEX_VERSION=$( jq -r '.cortexVersion' "product.json" )
    CORTEX_RELEASE=$( jq -r '.cortexRelease' "product.json" )
  elif jq -e '.voidVersion' product.json > /dev/null 2>&1; then
    CORTEX_VERSION=$( jq -r '.voidVersion' "product.json" )
    CORTEX_RELEASE=$( jq -r '.voidRelease' "product.json" )
  else
    CORTEX_VERSION="${MS_TAG}"
    CORTEX_RELEASE="0000"
  fi
  
  # Allow override via environment variable
  if [[ -n "${CORTEXIDE_RELEASE}" ]]; then
    CORTEX_RELEASE="${CORTEXIDE_RELEASE}"
  fi
  
  if [[ -n "${CORTEX_RELEASE}" ]]; then
    RELEASE_VERSION="${MS_TAG}${CORTEX_RELEASE}"
  else
    RELEASE_VERSION="${MS_TAG}0000"
  fi
  
  # CRITICAL: Validate RELEASE_VERSION is not empty
  if [[ -z "${RELEASE_VERSION}" ]]; then
    echo "Error: RELEASE_VERSION is empty. MS_TAG='${MS_TAG}', CORTEX_RELEASE='${CORTEX_RELEASE}'" >&2
    exit 1
  fi
fi


echo "RELEASE_VERSION=\"${RELEASE_VERSION}\""
echo "MS_COMMIT=\"${MS_COMMIT}\""
echo "MS_TAG=\"${MS_TAG}\""
echo "CORTEX_VERSION=\"${CORTEX_VERSION}\""

cd ..

# for GH actions
if [[ "${GITHUB_ENV}" ]]; then
  echo "MS_TAG=${MS_TAG}" >> "${GITHUB_ENV}"
  echo "MS_COMMIT=${MS_COMMIT}" >> "${GITHUB_ENV}"
  echo "RELEASE_VERSION=${RELEASE_VERSION}" >> "${GITHUB_ENV}"
  echo "CORTEX_VERSION=${CORTEX_VERSION}" >> "${GITHUB_ENV}"
fi



echo "----------- get_repo exports -----------"
echo "MS_TAG ${MS_TAG}"
echo "MS_COMMIT ${MS_COMMIT}"
echo "RELEASE_VERSION ${RELEASE_VERSION}"
echo "CORTEX_VERSION ${CORTEX_VERSION}"
echo "----------------------"


export MS_TAG
export MS_COMMIT
export RELEASE_VERSION
export CORTEX_VERSION

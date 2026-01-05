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
  
  # Phase 3: Source state verification (warn only, non-blocking)
  # Check main repo state to help identify potential issues
  if [[ -d "${CORTEXIDE_REPO}/.git" ]]; then
    cd "${CORTEXIDE_REPO}" 2>/dev/null || true
    # Check for uncommitted changes (warn but don't fail)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      echo "⚠️  Warning: Main repo has uncommitted changes - this may cause build inconsistencies"
    fi
    # Check if package-lock.json exists
    if [[ -f "package.json" ]] && [[ ! -f "package-lock.json" ]]; then
      echo "⚠️  Warning: package-lock.json missing in main repo - will be regenerated during build"
    fi
    cd - > /dev/null 2>&1 || true
  fi
  
  # Remove existing vscode directory if it exists
  rm -rf vscode
  
  # Copy the local CortexIDE repo to vscode directory (exclude heavy/temp files)
  # Phase 1: Expanded exclusions to prevent build artifacts from causing regressions
  echo "Copying CortexIDE repository to vscode directory..."
  mkdir -p vscode
  rsync -a --delete \
    --exclude ".git" \
    --exclude "node_modules" \
    --exclude "**/node_modules" \
    --exclude "out" \
    --exclude "out-build" \
    --exclude "out-vscode-min" \
    --exclude ".build" \
    --exclude ".cache" \
    --exclude "dist" \
    --exclude "build/out" \
    --exclude "*.tsbuildinfo" \
    --exclude "**/*.tsbuildinfo" \
    --exclude ".vscode" \
    --exclude "**/.vscode" \
    --exclude "src/vs/workbench/contrib/*/browser/react/out" \
    --exclude "**/react/out" \
    "${CORTEXIDE_REPO}/" "vscode/"
  
  # Phase 2: Post-copy cleanup to remove any artifacts that might have been copied
  # This ensures a completely clean state even if exclusions miss something
  cd vscode || { echo "'vscode' dir not found"; exit 1; }
  echo "Cleaning up any build artifacts that may have been copied..."
  rm -rf out out-build out-vscode-min .build .cache dist build/out 2>/dev/null || true
  find . -name "*.tsbuildinfo" -type f -delete 2>/dev/null || true
  find . -type d -path "*/browser/react/out" -exec rm -rf {} + 2>/dev/null || true
  
  # Phase 6: Normalize timestamps to prevent build cache issues
  # Touch key source files to ensure build system sees them as "new"
  echo "Normalizing file timestamps to prevent cache issues..."
  find src -name "*.ts" -type f -exec touch {} + 2>/dev/null || true
  find src -name "*.tsx" -type f -exec touch {} + 2>/dev/null || true
  
  # Phase 5: File integrity check - verify critical files exist after copy
  if [[ ! -f "package.json" ]]; then
    echo "Error: package.json not found after copy - copy may have failed"
    exit 1
  fi
  if [[ ! -f "product.json" ]]; then
    echo "Error: product.json not found after copy - copy may have failed"
    exit 1
  fi
  echo "✓ Critical files verified after copy"
  
  # Get version info from local repo
  MS_TAG=$( jq -r '.version' "package.json" )
  MS_COMMIT=$( git rev-parse HEAD 2>/dev/null || echo "local" )
  
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
else
  # Fallback to cloning from GitHub (for CI or if local repo not found)
  CORTEXIDE_BRANCH="main"
  echo "Local CortexIDE repo not found, cloning from GitHub ${CORTEXIDE_BRANCH}..."
  
  # Remove existing vscode directory if it exists
  rm -rf vscode
  
  mkdir -p vscode
  cd vscode || { echo "'vscode' dir not found"; exit 1; }
  
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
    git checkout "${CORTEXIDE_COMMIT}"
  else
    git fetch --depth 1 origin "${CORTEXIDE_BRANCH}"
    git checkout FETCH_HEAD
  fi
  
  MS_TAG=$( jq -r '.version' "package.json" )
  MS_COMMIT=$CORTEXIDE_BRANCH
  
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

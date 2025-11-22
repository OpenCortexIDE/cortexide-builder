#!/usr/bin/env bash
# shellcheck disable=SC2129

set -e

# Sensible defaults so downstream jobs always receive explicit values
SHOULD_BUILD="no"
SHOULD_DEPLOY="no"

case "${GITHUB_EVENT_NAME}" in
  pull_request)
    echo "It's a PR"
    SHOULD_BUILD="yes"
    SHOULD_DEPLOY="no"
    ;;
  push)
    echo "It's a Push"
    SHOULD_BUILD="yes"
    SHOULD_DEPLOY="no"
    ;;
  workflow_dispatch)
    if [[ "${GENERATE_ASSETS}" == "true" ]]; then
      echo "Manual dispatch to generate assets"
      SHOULD_BUILD="yes"
      SHOULD_DEPLOY="no"
    else
      echo "Manual dispatch for release"
      SHOULD_BUILD="yes"
      SHOULD_DEPLOY="yes"
    fi
    ;;
  repository_dispatch)
    echo "Repository dispatch trigger"
    SHOULD_BUILD="yes"
    SHOULD_DEPLOY="yes"
    ;;
  *)
    echo "It's a Cron or other scheduled trigger"
    SHOULD_BUILD="yes"
    SHOULD_DEPLOY="yes"
    ;;
esac

export SHOULD_BUILD
export SHOULD_DEPLOY

if [[ "${GITHUB_ENV}" ]]; then
  echo "GITHUB_BRANCH=${GITHUB_BRANCH}" >> "${GITHUB_ENV}"
  echo "SHOULD_BUILD=${SHOULD_BUILD}" >> "${GITHUB_ENV}"
  echo "SHOULD_DEPLOY=${SHOULD_DEPLOY}" >> "${GITHUB_ENV}"
  echo "VSCODE_QUALITY=${VSCODE_QUALITY}" >> "${GITHUB_ENV}"
fi

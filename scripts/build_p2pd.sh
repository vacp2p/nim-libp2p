#!/bin/bash

# Copyright (c) 2018-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e

force=false
verbose=false
CACHE_DIR=""
LIBP2P_COMMIT="124530a3"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -f|--force) force=true ;;
    -v|--verbose) verbose=true ;;
    -h|--help)
      echo "Usage: $0 [-f|--force] [-v|--verbose] [CACHE_DIR] [COMMIT]"
      exit 0
      ;;
    *)
      # First non-option is CACHE_DIR, second is LIBP2P_COMMIT
      if [[ -z "$CACHE_DIR" ]]; then
        CACHE_DIR="$1"
      elif [[ "$LIBP2P_COMMIT" == "124530a3" ]]; then
        LIBP2P_COMMIT="$1"
      else
        echo "Unknown argument: $1"
        exit 1
      fi
      ;;
  esac
  shift
done

SUBREPO_DIR="vendor/go/src/github.com/libp2p/go-libp2p-daemon"
if [[ ! -e "$SUBREPO_DIR" ]]; then
    SUBREPO_DIR="go-libp2p-daemon"
    rm -rf "$SUBREPO_DIR"
    git clone -q https://github.com/libp2p/go-libp2p-daemon
    cd "$SUBREPO_DIR"
    git checkout -q "$LIBP2P_COMMIT"
    cd ..
fi

## env vars
[[ -z "$BUILD_MSG" ]] && BUILD_MSG="Building p2pd ${LIBP2P_COMMIT}"

# Windows detection
if uname | grep -qiE "mingw|msys"; then
    EXE_SUFFIX=".exe"
    # otherwise it fails in AppVeyor due to https://github.com/git-for-windows/git/issues/2495
    GIT_TIMESTAMP_ARG="--date=unix" # available since Git 2.9.4
else
    EXE_SUFFIX=""
    GIT_TIMESTAMP_ARG="--date=format-local:%s" # available since Git 2.7.0
fi

TARGET_DIR="$(go env GOPATH)/bin"
TARGET_BINARY="${TARGET_DIR}/p2pd${EXE_SUFFIX}"

target_needs_rebuilding() {
    REBUILD=0
    NO_REBUILD=1

    if [[ -n "$CACHE_DIR" && -e "${CACHE_DIR}/p2pd${EXE_SUFFIX}" ]]; then
        mkdir -p "${TARGET_DIR}"
        cp -a "$CACHE_DIR"/* "${TARGET_DIR}/"
    fi

    # compare the built commit's timestamp to the date of the last commit (keep in mind that Git doesn't preserve file timestamps)
    if [[ -e "${TARGET_DIR}/timestamp" && $(cat "${TARGET_DIR}/timestamp") -eq $(cd "$SUBREPO_DIR"; git log --pretty=format:%cd -n 1 ${GIT_TIMESTAMP_ARG}) ]]; then
        return $NO_REBUILD
    else
        return $REBUILD
    fi
}

build_target() {
    echo -e "$BUILD_MSG"

    pushd "$SUBREPO_DIR"
    # Go module downloads can fail randomly in CI VMs, so retry them a few times
    MAX_RETRIES=5
    CURR=0
    while [[ $CURR -lt $MAX_RETRIES ]]; do
        FAILED=0
        go get ./... && break || FAILED=1
        CURR=$(( CURR + 1 ))
        if $verbose; then
            echo "retry #${CURR}"
        fi
    done
    if [[ $FAILED == 1 ]]; then
        echo "Error: still fails after retrying ${MAX_RETRIES} times."
        exit 1
    fi
    go install ./...

    # record the last commit's timestamp
    git log --pretty=format:%cd -n 1 ${GIT_TIMESTAMP_ARG} > "${TARGET_DIR}/timestamp"

    popd

    # update the CI cache
    if [[ -n "$CACHE_DIR" ]]; then
        rm -rf "$CACHE_DIR"
        mkdir "$CACHE_DIR"
        cp -a "$TARGET_DIR"/* "$CACHE_DIR"/
    fi
    echo "Binary built successfully: $TARGET_BINARY"
}

if $force || target_needs_rebuilding; then
    build_target
else
    echo "No rebuild needed."
fi


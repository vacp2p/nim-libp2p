#!/usr/bin/env bash
# used in Travis CI and AppVeyor scripts

# Copyright (c) 2018-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e

# Git commits
: ${CSOURCES_V1_COMMIT:=a8a5241f9475099c823cfe1a5e0ca4022ac201ff}
: ${CSOURCES_V2_COMMIT:=86742fb02c6606ab01a532a0085784effb2e753e}
: ${CSOURCES_V1_REPO:=https://github.com/nim-lang/csources_v1.git}
: ${CSOURCES_V2_REPO:=https://github.com/nim-lang/csources_v2.git}

# After this Nim commit, use csources v2
: ${CSOURCES_V2_START_COMMIT:=f7c203fb6c89b5cef83c4f326aeb23ef8c4a2c40}
: ${NIMBLE_COMMIT:=3575fd54a890d910ace56678aa74b4237d604175} # 0.14.2
# NIM_COMMIT could be a (partial) commit hash, a tag, a branch name, etc. Empty by default.
NIM_COMMIT_HASH="" # full hash for NIM_COMMIT, retrieved in "nim_needs_rebuilding()"

# script arguments
[[ $# -ne 4 ]] && { echo "Usage: $0 nim_dir csources_dir nimble_dir ci_cache_dir"; exit 1; }
NIM_DIR="$1"
CSOURCES_DIR="$2" # can be relative to NIM_DIR
NIMBLE_DIR="$3" # can be relative to NIM_DIR
CI_CACHE="$4"

## env vars
# verbosity level
[[ -z "$V" ]] && V=0
[[ -z "$CC" ]] && CC="gcc"
# to build csources in parallel, set MAKE="make -jN"
[[ -z "$MAKE" ]] && MAKE="make"
# for 32-bit binaries on a 64-bit host
UCPU=""
[[ "$ARCH_OVERRIDE" == "x86" ]] && UCPU="ucpu=i686"
[[ -z "$NIM_BUILD_MSG" ]] && NIM_BUILD_MSG="Building the Nim compiler"
[[ -z "$QUICK_AND_DIRTY_COMPILER" ]] && QUICK_AND_DIRTY_COMPILER=0
[[ -z "$QUICK_AND_DIRTY_NIMBLE" ]] && QUICK_AND_DIRTY_NIMBLE=0

# Windows detection
if uname | grep -qiE "mingw|msys"; then
	ON_WINDOWS=1
	EXE_SUFFIX=".exe"
	# otherwise it fails in AppVeyor due to https://github.com/git-for-windows/git/issues/2495
	GIT_TIMESTAMP_ARG="--date=unix" # available since Git 2.9.4
else
	ON_WINDOWS=0
	EXE_SUFFIX=""
	GIT_TIMESTAMP_ARG="--date=format-local:%s" # available since Git 2.7.0
fi

NIM_BINARY="${NIM_DIR}/bin/nim${EXE_SUFFIX}"
MAX_NIM_BINARIES="10" # Old ones get deleted.

nim_needs_rebuilding() {
	REBUILD=0
	NO_REBUILD=1

  echo "Nim is being rebuilt..."

	if [[ ! -e "$NIM_DIR" ]]; then
		# Shallow clone, optimised for the default NIM_COMMIT value.
		git clone -q --depth=1 https://github.com/status-im/Nim.git "$NIM_DIR"
	fi

	pushd "${NIM_DIR}" >/dev/null
	if [[ -n "${NIM_COMMIT}" ]]; then
		# support old Git versions, like the one from Ubuntu-18.04
		git restore . 2>/dev/null || git reset --hard
		if ! git checkout -q ${NIM_COMMIT} 2>/dev/null; then
			# Pay the price for a non-default NIM_COMMIT here, by fetching everything.
			# (This includes upstream branches and tags that might be missing from our fork.)
			git remote add upstream https://github.com/nim-lang/Nim
			git fetch --all --tags --quiet
			git checkout -q ${NIM_COMMIT}
		fi
		# In case the local branch diverged and a fast-forward merge is not possible.
		git fetch || true
		git reset -q --hard origin/${NIM_COMMIT} 2>/dev/null || true
		# In case NIM_COMMIT is a local branch that's behind the remote one it's tracking.
		git pull -q 2>/dev/null || true
		git checkout -q ${NIM_COMMIT}
		# We can't use "rev-parse" here, because it would return the tag object's
		# hash instead of the commit hash, when NIM_COMMIT is a tag.
		NIM_COMMIT_HASH="$(git rev-list -n 1 ${NIM_COMMIT})"
	else
		# NIM_COMMIT is empty, so assume the commit we need is already checked out
		NIM_COMMIT_HASH="$(git rev-list -n 1 HEAD)"
	fi
	popd >/dev/null

  if [[ ! -d "$NIMBLE_DIR" ]]; then
  	mkdir -p "$NIMBLE_DIR"
  	pushd "$NIMBLE_DIR"
  	git clone https://github.com/nim-lang/nimble.git .
  	git checkout $NIMBLE_COMMIT
  	# we have to delete .git or koch.nim will checkout a branch tip, overriding our target commit
  	rm -rf .git
  	popd
  fi
  if [[ "$NIMBLE_DIR" != "dist/nimble" ]]; then
  	mkdir -p dist
  	rm -rf dist/nimble
  	ln -s ../"$NIMBLE_DIR" dist/nimble
  fi

	if [[ -n "$CI_CACHE" && -d "$CI_CACHE" ]]; then
		cp -a "$CI_CACHE"/* "$NIM_DIR"/bin/ || true # let this one fail with an empty cache dir
	fi

	# Delete old Nim binaries, to put a limit on how much storage we use.
	for F in "$(ls -t "${NIM_DIR}"/bin/nim_commit_* 2>/dev/null | tail -n +$((MAX_NIM_BINARIES + 1)))"; do
		if [[ -e "${F}" ]]; then
			rm "${F}"
		fi
	done

	# Compare the last built commit to the one requested.
	# Handle the scenario where our symlink is manually deleted by the user.
	if [[ -e "${NIM_DIR}/bin/last_built_commit" && \
	-e "${NIM_DIR}/bin/nim${EXE_SUFFIX}" && \
	"$(cat "${NIM_DIR}/bin/last_built_commit")" == "${NIM_COMMIT_HASH}" ]]; then
		return $NO_REBUILD
	elif [[ -e "${NIM_DIR}/bin/nim_commit_${NIM_COMMIT_HASH}" ]]; then
		# we built the requested commit in the past, so we simply reuse it
		rm -f "${NIM_DIR}/bin/nim${EXE_SUFFIX}"
		ln -s "nim_commit_${NIM_COMMIT_HASH}" "${NIM_DIR}/bin/nim${EXE_SUFFIX}"
		echo ${NIM_COMMIT_HASH} > "${NIM_DIR}/bin/last_built_commit"
		return $NO_REBUILD
	else
		return $REBUILD
	fi
}

build_nim() {
	echo -e "$NIM_BUILD_MSG"
	[[ "$V" == "0" ]] && exec &>/dev/null

	# working directory
	pushd "$NIM_DIR"

  echo "Running build_nim"

	if grep -q skipIntegrityCheck koch.nim; then
		# Run Nim buildchain
		. ci/funs.sh
		echo "Building with default buildchain"
		NIMCORES=1 nimBuildCsourcesIfNeeded $UCPU
		bin/nim c --noNimblePath --skipUserCfg --skipParentCfg --warnings:off --hints:off koch
		./koch --skipIntegrityCheck boot -d:release --skipUserCfg --skipParentCfg --warnings:off --hints:off
		if [[ "${QUICK_AND_DIRTY_COMPILER}" == "0" ]]; then
			# We want tools
			./koch tools -d:release --skipUserCfg --skipParentCfg --warnings:off --hints:off
		elif [[ "${QUICK_AND_DIRTY_NIMBLE}" != "0" ]]; then
			# We just want nimble
			./koch nimble -d:release --skipUserCfg --skipParentCfg --warnings:off --hints:off
		fi
	else
		# Custom buildchain for older versions
		# TODO Remove this once the default NIM_COMMIT supports `--skipIntegrityCheck`
		# We will still be able to compile older versions by removing the flag,
		# which will just waste a bit of CPU

    echo "Building with custom buildchain"
		# Git repos for csources and Nimble
		if [[ ! -d "$CSOURCES_DIR" ]]; then
			if git merge-base --is-ancestor $CSOURCES_V2_START_COMMIT $NIM_COMMIT_HASH; then
			  CSOURCES_REPO=$CSOURCES_V2_REPO
			  CSOURCES_COMMIT=$CSOURCES_V2_COMMIT
			else
			  CSOURCES_REPO=$CSOURCES_V1_REPO
			  CSOURCES_COMMIT=$CSOURCES_V1_COMMIT
			fi

			mkdir -p "$CSOURCES_DIR"
			pushd "$CSOURCES_DIR"
			git clone $CSOURCES_REPO .
			git checkout $CSOURCES_COMMIT
			popd
		fi
		if [[ "$CSOURCES_DIR" != "csources" ]]; then
			rm -rf csources
			ln -s "$CSOURCES_DIR" csources
		fi

		if [[ ! -d "$NIMBLE_DIR" ]]; then
			mkdir -p "$NIMBLE_DIR"
			pushd "$NIMBLE_DIR"
			git clone https://github.com/nim-lang/nimble.git .
			git checkout $NIMBLE_COMMIT
			# we have to delete .git or koch.nim will checkout a branch tip, overriding our target commit
			rm -rf .git
			popd
		fi
		if [[ "$NIMBLE_DIR" != "dist/nimble" ]]; then
			mkdir -p dist
			rm -rf dist/nimble
			ln -s ../"$NIMBLE_DIR" dist/nimble
		fi

		# bootstrap the Nim compiler and build the tools
		rm -f bin/{nim,nim_csources}
		pushd csources
		if [[ "$ON_WINDOWS" == "0" ]]; then
			$MAKE $UCPU clean
			$MAKE $UCPU LD=$CC
		else
			$MAKE myos=windows $UCPU clean
			$MAKE myos=windows $UCPU CC=gcc LD=gcc
		fi
		popd
		if [[ -e csources/bin ]]; then
			rm -f bin/nim bin/nim_csources
			cp -a csources/bin/nim bin/nim
			cp -a csources/bin/nim bin/nim_csources
			rm -rf csources/bin
		else
			cp -a bin/nim bin/nim_csources
		fi
		if [[ "$QUICK_AND_DIRTY_COMPILER" == "0" ]]; then
			sed \
				-e 's/koch$/--warnings:off --hints:off koch/' \
				-e 's/koch boot/koch boot --warnings:off --hints:off/' \
				-e '/nimBuildCsourcesIfNeeded/d' \
				build_all.sh > build_all_custom.sh
			sh build_all_custom.sh
			rm build_all_custom.sh
		else
			# Don't re-build it multiple times until we get identical
			# binaries, like "build_all.sh" does. Don't build any tools
			# either. This is all about build speed, not developer comfort.
			bin/nim_csources \
				c \
				--compileOnly \
				--nimcache:nimcache \
				-d:release \
				--skipUserCfg \
				--skipParentCfg \
				--warnings:off \
				--hints:off \
				compiler/nim.nim
			bin/nim_csources \
				jsonscript \
				--nimcache:nimcache \
				--skipUserCfg \
				--skipParentCfg \
				compiler/nim.nim
			cp -a compiler/nim bin/nim1
			# If we stop here, we risk ending up with a buggy compiler:
			# https://github.com/status-im/nimbus-eth2/pull/2220
			# https://github.com/status-im/nimbus-eth2/issues/2310
			bin/nim1 \
				c \
				--compileOnly \
				--nimcache:nimcache \
				-d:release \
				--skipUserCfg \
				--skipParentCfg \
				--warnings:off \
				--hints:off \
				compiler/nim.nim
			bin/nim1 \
				jsonscript \
				--nimcache:nimcache \
				--skipUserCfg \
				--skipParentCfg \
				compiler/nim.nim
			rm -f bin/nim
			cp -a compiler/nim bin/nim
			rm bin/nim1

			# Do we want Nimble in this quick build?
			if [[ "${QUICK_AND_DIRTY_NIMBLE}" != "0" ]]; then
				bin/nim c -d:release --noNimblePath --skipUserCfg --skipParentCfg dist/nimble/src/nimble.nim
				mv dist/nimble/src/nimble bin/
			fi
		fi
	fi

	if [[ "$QUICK_AND_DIRTY_COMPILER" == "0" || "${QUICK_AND_DIRTY_NIMBLE}" != "0" ]]; then
		# Nimble needs a CA cert
		rm -f bin/cacert.pem
		curl -LsS -o bin/cacert.pem https://curl.se/ca/cacert.pem || echo "Warning: 'curl' failed to download a CA cert needed by Nimble. Ignoring it."
	fi

	# record the built commit
	echo ${NIM_COMMIT_HASH} > bin/last_built_commit

	# create the symlink
	mv bin/nim bin/nim_commit_${NIM_COMMIT_HASH}
	ln -s nim_commit_${NIM_COMMIT_HASH} bin/nim${EXE_SUFFIX}

	# update the CI cache
	popd # we were in $NIM_DIR
	if [[ -n "$CI_CACHE" ]]; then
		rm -rf "$CI_CACHE"
		mkdir "$CI_CACHE"
		cp "$NIM_DIR"/bin/* "$CI_CACHE"/
	fi
}

if nim_needs_rebuilding; then
	build_nim
fi

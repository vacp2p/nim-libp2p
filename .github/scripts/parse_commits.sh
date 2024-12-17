#!/usr/bin/env bash

# The output of this script is as follows:
# 1. One line "checking commits between: <start_commit> <end_commit>"
# 2. One line for each commit message that is not well-formed

set -euo pipefail

source .github/scripts/colors.sh

parse_commits() {

    BASE_BRANCH=${BASE_BRANCH:-master}

    start_commit=${1:-origin/${BASE_BRANCH}}
    end_commit=${2:-HEAD}
    exit_code=0

    echo -e "${GRN}Checking commits between:${RST} $start_commit $end_commit"
    # Run the loop in the current shell using process substitution
    while IFS= read -r message || [ -n "$message" ]; do
        # Check if commit message follows conventional commits format
        if [[ ! $message =~ ^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\(.*\))?:.*$ ]]; then
            echo -e "${YLW}Commit message is ill-formed:${RST} $message"
            exit_code=1
        fi
    done < <(git log --format=%s "$start_commit".."$end_commit")

    exit ${exit_code}
}
#!/usr/bin/env bash
# Commits a CI log back into the repository.
#
# Actions logs are served from blob storage that the development sandbox cannot
# reach, so build output has to come back through git. Each job publishes to its
# own file to keep concurrent jobs from fighting over the same path.
set -u

log_path="${1:?usage: publish_log.sh <path>}"

mkdir -p .ci
{
	echo "workflow: ${GITHUB_WORKFLOW:-local}"
	echo "job: ${GITHUB_JOB:-local}"
	echo "run: ${GITHUB_RUN_ID:-local}"
	echo "commit: ${GITHUB_SHA:-local}"
	echo "status: ${JOB_STATUS:-unknown}"
} > "${log_path}.meta"

git config user.email "ci@arena.ai"
git config user.name "arena-ci"

for attempt in 1 2 3; do
	git add "$log_path" "${log_path}.meta" || true
	if git diff --cached --quiet; then
		echo "nothing to publish for $log_path"
		exit 0
	fi
	git commit -q -m "ci: build log ($(basename "$log_path")) [skip ci]" || true
	git pull --rebase --autostash -q origin arena/01a0ba62-roblox >/dev/null 2>&1 || true
	if git push -q origin HEAD:arena/01a0ba62-roblox 2>/dev/null; then
		echo "published $log_path"
		exit 0
	fi
	echo "push attempt $attempt failed, retrying"
	sleep 5
done

echo "could not publish $log_path" >&2
exit 1

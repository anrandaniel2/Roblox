#!/usr/bin/env bash
# Commits a CI log back into the repository.
#
# Actions logs are served from blob storage that the development sandbox cannot
# reach, so build output has to come back through git. Each job publishes to its
# own file to keep concurrent jobs from fighting over the same path.
set -u

log_path="${1:?usage: publish_log.sh <path>}"

mkdir -p .ci
if [ ! -s "$log_path" ]; then
	echo "(no output was captured for this job)" > "$log_path"
fi
{
	echo ""
	echo "--- ${GITHUB_WORKFLOW:-local} / ${GITHUB_JOB:-local} / run ${GITHUB_RUN_ID:-local} / status ${JOB_STATUS:-unknown} / $(date -u +%Y-%m-%dT%H:%M:%SZ) ---"
} >> "$log_path"

git config user.email "ci@arena.ai"
git config user.name "arena-ci"

for attempt in 1 2 3; do
	git add -A .ci
	if git diff --cached --quiet; then
		# Never report success without publishing something.
		echo "retry marker ${attempt} $(date -u +%s)" >> "$log_path"
		git add -A .ci
	fi
	git commit -q -m "ci: build log ($(basename "$log_path")) [skip ci]" || true
	git pull --rebase --autostash -q origin arena/01a0ba62-roblox >/dev/null 2>&1 || true
	if git push -q origin HEAD:arena/01a0ba62-roblox 2>/dev/null; then
		echo "published $log_path"
		exit 0
	fi
	echo "push attempt ${attempt} failed, retrying"
	sleep 5
done

echo "could not publish $log_path" >&2
git --no-pager log --oneline -3 >&2 || true
exit 1

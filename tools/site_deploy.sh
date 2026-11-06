#!/bin/bash
# Publishes a Team Create server's project when someone presses Deploy to Website in the plugin.
# Runs on the server machine, outside the container, and is the only part that can reach the site.
#
#   site_deploy.sh           waits for requests
#   site_deploy.sh --once    publishes once right now and exits
#
# Settings go in $DEPLOY_BASE/deploy.env, which is kept out of the repo:
#   SITE=user@host:/var/www/mygame/   where the build is uploaded, any rsync destination
#   PRESET=Web                        optional, the export preset's name
#   BUILD=build                       optional, the folder that preset exports into
#   REQUIRED_FILES="index.html index.pck index.wasm"   optional, must exist before uploading
#
# Expected in $DEPLOY_BASE:
#   project/          the server's project, read only here
#   deploy/request/   written by the server, mounted into the container
#   deploy/status/    written here, mounted read only into the container
set -u

BASE="${DEPLOY_BASE:-/srv/team-create}"
GODOT="${GODOT:-godot}"
PRESET=Web
BUILD=build
REQUIRED_FILES="index.html index.pck index.wasm"
SITE=
. "$BASE/deploy.env" || exit 1
if [ -z "$SITE" ]; then
	echo "SITE isn't set in $BASE/deploy.env"
	exit 1
fi

WORK="$BASE/deploy/work"
PREVIOUS="$BASE/deploy/build.previous"
REQUEST="$BASE/deploy/request/current"
STATUS="$BASE/deploy/status/current"
LOG="$BASE/deploy/last.log"
ID=manual

# A crashed export can otherwise leave a core file of several hundred MB behind
ulimit -c 0

status() {
	printf '{"id":"%s","state":"%s","message":"%s"}\n' "$ID" "$1" "$2" > "$STATUS.tmp"
	mv "$STATUS.tmp" "$STATUS"
	echo "$(date '+%F %T') $1: $2"
}

publish() {
	mkdir -p "$WORK/$BUILD"

	status running "Copying the project"
	# A copy, so edits made during the export can't end up half in the build
	if ! rsync -a --delete --exclude=/.godot --exclude="/$BUILD" --exclude=/addons/team_create \
			--exclude=/.team_create "$BASE/project/" "$WORK/" > "$LOG" 2>&1; then
		status failed "Couldn't copy the project"
		return 1
	fi
	# The server's project.godot starts the Team Create server instead of the game
	grep -v '^run/main_scene="res://addons/team_create/' "$BASE/project/project.godot" > "$WORK/project.godot"

	if [ -s "$WORK/$BUILD/index.html" ]; then
		rsync -a --delete "$WORK/$BUILD/" "$PREVIOUS/" >> "$LOG" 2>&1
	fi
	find "$WORK/$BUILD" -maxdepth 1 -type f -delete

	status running "Importing assets"
	if ! nice -n 10 timeout 900 "$GODOT" --headless --path "$WORK" --import >> "$LOG" 2>&1; then
		status failed "The import failed, so the site wasn't changed"
		return 1
	fi

	status running "Exporting the game"
	if ! nice -n 10 timeout 900 "$GODOT" --headless --path "$WORK" --export-release "$PRESET" >> "$LOG" 2>&1; then
		status failed "The export failed, so the site wasn't changed"
		return 1
	fi
	# Uploading with --delete would empty the site if the export produced nothing
	for file in $REQUIRED_FILES; do
		if [ ! -s "$WORK/$BUILD/$file" ]; then
			status failed "The export didn't produce $file, so the site wasn't changed"
			return 1
		fi
	done

	status running "Uploading to the site"
	if ! rsync -a --delete -e "ssh -o BatchMode=yes -o ConnectTimeout=20" "$WORK/$BUILD/" "$SITE" >> "$LOG" 2>&1; then
		status failed "The upload failed, so the site may be incomplete. Try deploying again"
		return 1
	fi

	status done "The site is up to date"
}

if [ "${1:-}" = "--once" ]; then
	publish
	exit $?
fi

# Whatever was requested while this wasn't running is old by now, and shouldn't publish on startup
SEEN="$(cat "$REQUEST" 2>/dev/null)"
echo "Waiting for deploy requests"
while true; do
	CURRENT="$(cat "$REQUEST" 2>/dev/null)"
	if [ "$CURRENT" != "$SEEN" ]; then
		SEEN="$CURRENT"
		if [[ "$CURRENT" =~ ^[0-9]+$ ]]; then
			ID="$CURRENT"
			publish
		fi
	fi
	sleep 2
done

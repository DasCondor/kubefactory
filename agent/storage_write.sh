set -eu
umask 077
fail() { printf 'ERROR %s\n' "$1"; exit 1; }
root=$1
file=$2
expected=$3
size=$4
prefix=${root%/}
case "$file" in "$prefix"/*) ;; *) fail 'Path is outside the mounted directory.' ;; esac
[ -d "$root" ] && [ ! -L "$root" ] || fail 'The mount must be a real directory.'
parent=${file%/*}
check_path() {
    dir=$parent
    while [ "$dir" != "$root" ]; do
        [ -d "$dir" ] && [ ! -L "$dir" ] || fail 'Linked directories cannot be edited.'
        dir=${dir%/*}
        [ -n "$dir" ] || dir=/
    done
    [ -f "$file" ] && [ ! -L "$file" ] || fail 'Only existing regular files can be edited.'
    [ "$(wc -c < "$file")" -le 65536 ] || fail 'File is too large to edit.'
    actual=$(sha256sum < "$file")
    [ "${actual%% *}" = "$expected" ] || fail 'File changed since it was opened. Reopen it before saving.'
}
check_path
# One lock per file also prevents two KubeFactory editors replacing it together.
lock="$file.kf-write-lock"
mkdir -- "$lock" 2>/dev/null || fail 'Another save is in progress (or this directory is read-only).'
stage=''
saved=0
cleanup() {
    if [ -n "$stage" ] && [ "$saved" = 0 ]; then
        rm -f -- "$stage/updated" "$stage/previous"
        rmdir -- "$stage" 2>/dev/null || true
    fi
    rmdir -- "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
stage=$(mktemp -d "$parent/.kf-edit.XXXXXX")
cp -p -- "$file" "$stage/previous"
backup_hash=$(sha256sum < "$stage/previous")
[ "${backup_hash%% *}" = "$expected" ] || fail 'File changed while making its backup. Reopen it before saving.'
cp -p -- "$stage/previous" "$stage/updated"
IFS= read -r payload || fail 'No file contents were received.'
printf '%s' "$payload" | base64 -d > "$stage/updated" || fail 'Invalid file contents.'
[ "$(wc -c < "$stage/updated")" = "$size" ] || fail 'File contents were incomplete.'
check_path
mv -f -- "$stage/updated" "$file" || fail 'Cannot replace this file; single-file mounts must be edited at their source.'
saved=1
printf 'OK %s/previous\n' "$stage"

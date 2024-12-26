#!/bin/sh

. .helpers/lib-run.sh
_compute_default_vars
_handle_show_image_name "$@"

[ -n "$image" ] || { echo ".helpers/_runOnce.sh is expecting 'image'"; exit 1; }

rw_vols=/webhome/$user

if [ -n "$subdir" ]; then
    workdir=/webhome/$user/$subdir
else
    workdir=/webhome/$user
fi

# do not use default ENTRYPOINT
opts="$opts --entrypoint="

_docker_runOnce "$@"
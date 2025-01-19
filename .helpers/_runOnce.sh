#!/bin/sh

. .helpers/lib-run.sh
_compute_default_vars
_handle_show_image_name "$@"

[ -n "$image" ] || { echo ".helpers/_runOnce.sh is expecting 'image'"; exit 1; }

rw_vols=$user_home

if [ "$1" = "--cd" ]; then
    shift
    subdir="$1"
    shift
fi

case "$subdir" in
    /*) workdir=$subdir ;;
    ?*) workdir=$user_home/$subdir ;;
    *) workdir=$user_home ;;
esac

if [ ! -e $workdir ]; then
    echo "invalid workdir $workdir"
    exit 1
fi

# do not use default ENTRYPOINT
opts="$opts --entrypoint="

_docker_runOnce "$@"
#!/bin/sh

. .helpers/lib-run--set-vars.sh

rw_vols=$user_home

if [ "$1" = "--cd" ]; then
    shift
    subdir="$1"
    shift
fi

if [ -z "$1" ]; then
    # gérer "cmd=xxx" dans runOnce.env
    if [ -n "$cmd" ]; then
        # set $@ from $cmd
        set -- $cmd
    else
        echo "ERROR: pas de paramètre fournit à runOnce"
        exit 1
    fi
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

# pouvoir voir les processes de l'hôte (et donc les containeurs)
# utile pour jstack
opts="$opts --pid=host"
 
# do not use default ENTRYPOINT
opts="$opts --entrypoint="

if [ -z "$QUIET" ]; then
  echo "Running $@ ($image)" >&2
fi

_docker_runOnce "$@"
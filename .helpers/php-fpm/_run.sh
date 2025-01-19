#!/bin/sh

#set -x
set -o errexit

. .helpers/lib-run.sh
_compute_default_vars

_handle_show_image_name "$@"

if [ -z "$subdir" ]; then
    subdir=www
fi

run_user=fpm
run_group=$user

ro_vols="$ro_vols /usr/local/etc/ssl /var/run/mysqld"
rw_vols="$rw_vols /webhome/$user/$subdir"

_may_rename_kill_or_rm QUIT
if [ "$rc" = killed ]; then 
    # grâce au mount-bind que fait docker, on peut faire que
    # - dans le conteneur qui s'arrête, /run/php/fpm.sock est $user_home/.old-run/fpm.sock
    # - dans le conteneur qui démarre,  /run/php/fpm.sock est $user_home/.run/fpm.sock
    rm -rf $user_home/.old-run
    mv $user_home/.run $user_home/.old-run
    # le répertoire pour le conteneur qui démarre est créé ci-dessous :
fi
# (droits restreints pour que les utilisateurs sur l'hôte ne puissent pas voir les sessions/sockets des autres)
install -d -o $user -g $user -m 770 $user_home/.run /var/lib/php/sessions-$user
rw_vols="$rw_vols $user_home/.run:/run/php /var/lib/php/sessions-$user:/var/lib/php/sessions"


_docker_run

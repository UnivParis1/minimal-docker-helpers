#!/bin/sh

#set -x
set -o errexit

. .helpers/lib-run.sh
_compute_default_vars

if [ -z "$image" ]; then
	image=up1-php-fpm-7.4
fi
_handle_show_image_name "$@"

run_user=fpm
run_group=$user

ro_vols="$ro_vols /etc/shadow /usr/local/etc/ssl"
rw_vols="$rw_vols /webhome/$user/www /var/run/mysqld"

_may_rename_kill_or_rm QUIT
if [ "$rc" = killed ]; then 
    # grâce au mount-bind que fait docker, on peut faire que
    # - dans le conteneur qui s'arrête, /run/php/fpm.sock est /webhome/$user/.old-run/fpm.sock
    # - dans le conteneur qui démarre,  /run/php/fpm.sock est /webhome/$user/.run/fpm.sock
    rm -rf /webhome/$user/.old-run
    mv /webhome/$user/.run /webhome/$user/.old-run
    # le répertoire pour le conteneur qui démarre est créé ci-dessous :
fi
# (droits restreints pour que les utilisateurs sur l'hôte ne puissent pas voir les sessions/sockets des autres)
install -d -o $user -g $user -m 770 /webhome/$user/.run /var/lib/php/sessions-$user
rw_vols="$rw_vols /webhome/$user/.run:/run/php /var/lib/php/sessions-$user:/var/lib/php/sessions"


_docker_run

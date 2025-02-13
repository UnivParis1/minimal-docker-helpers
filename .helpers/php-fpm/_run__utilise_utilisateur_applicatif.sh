#!/bin/sh

#set -x
set -o errexit

base_dir_template='$user_home/www'

. .helpers/lib-run--set-vars.sh

run_user=$user
run_group=www-data

ro_vols="$ro_vols /usr/local/etc/ssl $base_dir /var/run/mysqld /run/systemd/journal/dev-log:/dev/log"


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


_docker_run --define syslog.ident=$container_name:docker-fpm

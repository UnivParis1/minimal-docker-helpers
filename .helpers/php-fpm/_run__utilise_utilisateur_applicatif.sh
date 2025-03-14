#!/bin/sh

#set -x
set -o errexit

base_dir_template='$user_home/www'

. .helpers/lib-run--set-vars.sh

run_user=$user
run_group=www-data

# on monte $base_dir read-only, mais uniquement s'il n'est pas read-write dans run.env (pour éviter l'erreur "Duplicate mount point")
for i in $rw_vols; do
    if [ $i = $base_dir ]; then
        base_dir_mounted_rw=1
    fi
done
if [ -z "$base_dir_mounted_rw" ]; then
    ro_vols="$ro_vols $base_dir"
fi

# à supprimer ?
ro_vols="$ro_vols /usr/local/etc/ssl"

# accéder au mysql de l'hôte
ro_vols="$ro_vols /var/run/mysqld"

# pour permettre syslog dans le conteneur ( https://github.com/prigaux/notes/blob/main/FPM-et-messages-de-logs-de-PHP.md )
ro_vols="$ro_vols /run/systemd/journal/dev-log:/dev/log"


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

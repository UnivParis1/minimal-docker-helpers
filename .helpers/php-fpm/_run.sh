#!/bin/sh

#set -x
set -o errexit

default_subdir=www
base_dir_template='$user_home/$subdir'

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

# plutôt que d'installer "ca-certificates" dans l'image, on fournit les certificats de l'hote. Cela permet notamment de fournir AC.univ-paris1.fr.pem (y compris dans le fichier généré /etc/ssl/certs/ca-certificates.crt )
ro_vols="$ro_vols /etc/ssl/certs /usr/share/ca-certificates /usr/local/share/ca-certificates"
# on fournit /usr/lib/ssl/certs utilisé notamment par PHP fopen/file_get_contents
# NB: si openssl est installé dans l'image, /usr/lib/ssl/certs est un symlink vers /etc/ssl/certs dans l'image. Cela forcera en fait le montage de /etc/ssl/certs sur /etc/ssl/certs, ce qui n'est pas un pb.
ro_vols="$ro_vols /etc/ssl/certs:/usr/lib/ssl/certs"

# à supprimer ?
ro_vols="$ro_vols /usr/local/etc/ssl"

# accéder au mysql de l'hôte
ro_vols="$ro_vols /var/run/mysqld"

# pour permettre syslog dans le conteneur ( https://github.com/prigaux/notes/blob/main/FPM-et-messages-de-logs-de-PHP.md )
ro_vols="$ro_vols /run/systemd/journal/dev-log:/dev/log"

run_suffix=""
if [ $subdir != $default_subdir ]; then
   run_suffix="--$subdir"
fi

    run_dir=$user_home/.run$run_suffix
old_run_dir=$user_home/.old-run$run_suffix

_may_rename_kill_or_rm QUIT
if [ "$rc" = killed ]; then 
    # grâce au mount-bind que fait docker, on peut faire que
    # - dans le conteneur qui s'arrête, /run/php/fpm.sock est $old_run_dir/fpm.sock
    # - dans le conteneur qui démarre,  /run/php/fpm.sock est $run_dir/fpm.sock
    rm -rf $old_run_dir
    mv $run_dir $old_run_dir
    # le répertoire pour le conteneur qui démarre est créé ci-dessous :
fi
# (droits restreints pour que les utilisateurs sur l'hôte ne puissent pas voir les sessions/sockets des autres)
install -d -o $user -g $user -m 770 $run_dir /var/lib/php/sessions-$user
rw_vols="$rw_vols $run_dir:/run/php /var/lib/php/sessions-$user:/var/lib/php/sessions"


_docker_run --define syslog.ident=$container_name:docker-fpm

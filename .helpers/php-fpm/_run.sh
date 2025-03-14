#!/bin/sh

#set -x
set -o errexit

base_dir_template='$user_home/www'

. .helpers/lib-run--set-vars.sh

run_user=fpm
run_group=$user

# plutôt que d'installer "ca-certificates" dans l'image, on fournit les certificats de l'hote. Cela permet notamment de fournir AC.univ-paris1.fr.pem (y compris dans le fichier généré /etc/ssl/certs/ca-certificates.crt )
ro_vols="$ro_vols /etc/ssl/certs /usr/share/ca-certificates /usr/local/share/ca-certificates"
# on fournit aussi les liens symboliques pour PHP fopen/file_get_contents (symlinks fournis par le paquet "openssl")
ro_vols="$ro_vols /usr/lib/ssl/certs /usr/lib/ssl/cert.pem"

# à supprimer ?
ro_vols="$ro_vols /usr/local/etc/ssl"

# accéder au mysql de l'hôte
ro_vols="$ro_vols /var/run/mysqld"

# pour permettre syslog dans le conteneur ( https://github.com/prigaux/notes/blob/main/FPM-et-messages-de-logs-de-PHP.md )
ro_vols="$ro_vols /run/systemd/journal/dev-log:/dev/log"

rw_vols="$rw_vols $base_dir"

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

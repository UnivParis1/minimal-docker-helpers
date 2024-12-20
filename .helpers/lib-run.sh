. .helpers/lib.sh

# variables gérés :
# - $container_name
# - $0
# variables ajoutées si vides :
# - $app_build_dir : répertoire /otp/dockers/xxx/
# - $container_name : noms du conteneur docker
# - $image : image docker à utiliser
# - $user : utilisateurs applicatifs possédant les fichiers
# - $logdir : répertoire conseillé pour mettre les logs
_compute_default_vars() {
    if [ -n "$container_name" ]; then
        app_build_dir=/opt/dockers/$container_name
    else
        app_build_dir=${0%/run.sh}
        container_name=${app_build_dir#*/}
    fi

    if [ -z "$image" ]; then
        if [ -e $app_build_dir/Dockerfile ]; then
            image=up1-$container_name
        fi
    fi

    if [ -z "$user" ]; then
        user=$container_name
    fi
    # convention : l'appli met ses fichiers de logs dans /var/log/xxx/ et les logs tomcat sont mis dans /var/log/xxx/tomcat/
    if [ -z "$logdir" ]; then
        logdir=/var/log/$container_name
    fi
}

_handle_show_image_name() {
    if [ "$1" = "--show-image-name" ]; then
        echo $image
        exit
    fi
}

_may_stop_and_rm() {
  if _container_exists $container_name; then 
    if [ `_container_status $container_name` = "running" ]; then
        echo "Stopping $container_name"
        docker stop $container_name >/dev/null
    fi
    docker rm $container_name >/dev/null
  fi
}

_may_rename_kill_or_rm() {
  old_name=old-$container_name

  if _container_exists $old_name; then 
    if [ `_container_status $old_name` = "running" ]; then
        echo "ERROR : le vieux conteneur tourne toujours. Veuillez attendre ou forcer avec 'docker stop $old_name'"
        exit 1
    fi
    # on supprime le vieux conteneur qui a été stoppé par le kill précédent (si "docker system prune" ne l'a pas supprimé)
    docker rm $old_name >/dev/null
  fi
  
  if _container_exists $container_name; then
    if [ `_container_status $container_name` = "running" ]; then
      # on renomme le précédent containeur
      docker container rename $container_name $old_name
      # on lui dit de s'arrêter en continuant à traiter les requêtes en cours
      echo "Graceful stop $old_name"
      docker kill --signal=$1 $old_name >/dev/null
      rc=killed
    else
      # le conteneur ne tourne pas, on le supprime
      docker rm $container_name >/dev/null
    fi
  fi
}

may_configure_rsyslog_and_logrotate() {
  rsyslog_conf_file=/etc/rsyslog.d/docker-containers-separate-files.conf
  if [ ! -e $rsyslog_conf_file ]; then
    echo "Installing $rsyslog_conf_file and restarting rsyslog"
    ln -s /opt/dockers/.helpers/various/rsyslog.conf $rsyslog_conf_file
    systemctl restart rsyslog
  fi
  logrotate_conf_file=/etc/logrotate.d/docker-containers.conf
  if [ ! -e $logrotate_conf_file ]; then
    echo "Installing $logrotate_conf_file"
    ln -s /opt/dockers/.helpers/various/logrotate.conf $logrotate_conf_file
  fi
}

compute_docker_run_opts() {
  for vol in $ro_vols; do
    case $vol in
      *:*) opts="$opts --volume $vol:ro" ;;
      *) opts="$opts --volume $vol:$vol:ro" ;;
    esac
  done
  for vol in $rw_vols; do
    case $vol in
      *:*) opts="$opts --volume $vol" ;;
      *) opts="$opts --volume $vol:$vol" ;;
    esac
  done
}

# variables nécessaires :
# - $run_user/$run_group ou $user
# - $container_name
# - $image
# variables gérés :
# - $ro_vols : contient les fichiers de l'hote à rendre visible read-only
# - $rw_vols : contient les fichiers de l'hote à rendre visible read-write
# - $network_driver : par défaut le driver "host" est utilisé
# - $opts : options diverses
_docker_run() {

  # NB: /etc/passwd nécessaire à pas mal d'applis (esup-activ pour kadmin, FPM ?) car on utilise le $user de l'hôte
  ro_vols="$ro_vols /etc/passwd /etc/group /etc/timezone"

  if [ -z "$run_user" ]; then
    run_user=$user
  fi
  if [ -z "$run_group" ]; then
    run_group=$user
  fi
  # NB: "--user $run_user:$run_group" ne marche pas car c'est le /etc/passwd de l'image qui est utilisé
  opts="--user `id -u $run_user`:`id -g $run_group` $opts"

  may_configure_rsyslog_and_logrotate
  opts="--log-driver syslog --log-opt tag={{.Name}}:docker:{{.ID}}: $opts"

  if [ -z "$network_driver" ]; then
    network_driver=host
  fi
  opts="--network $network_driver $opts"
  opts="--detach --restart unless-stopped $opts"

  compute_docker_run_opts

  docker run $opts --name $container_name $image "$@" >/dev/null
  
  echo "Created $container_name ($image). Status: "`_container_status $container_name`
}

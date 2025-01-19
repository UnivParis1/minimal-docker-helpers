. .helpers/lib.sh

# variables gérés :
# - $container_name
# - $0
# variables ajoutées si vides :
# - $app_build_dir : répertoire /otp/dockers/xxx/
# - $container_name : noms du conteneur docker
# - $user : utilisateurs applicatifs possédant les fichiers. calculé à partir du $container_name "<user>--<subdir>"
# - $logdir : répertoire conseillé pour mettre les logs
# variables parfois ajoutées si vides :
# - $image : si Dockerfile présent, nom de l'image construite pour le Dockerfile
# - $subdir : calculé à partir du $container_name "<user>--<subdir>"
_compute_default_vars() {
    if [ -n "$container_name" ]; then
        app_build_dir=/opt/dockers/$container_name
    else
        app_build_dir=${0%/run*.sh}
        container_name=${app_build_dir#*/}
    fi

    if [ "$action" = run -a -z "$image" ]; then
        if [ -e $app_build_dir/Dockerfile ]; then
            image=up1-$container_name
        fi
    fi

    if [ -z "$user" ]; then
        # le format du nom de container est "user" ou "user--xxx"
        user=${container_name%--*}
    fi
    if [ -z "$subdir" ]; then
        local subdir_=${container_name#*--}
        if [ $subdir_ != $container_name ]; then
            subdir=$subdir_
        fi
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
      # on s'assure que s'il ne termine pas, il ne sera pas redémarré au reboot
      docker update --restart=no $container_name >/dev/null
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
    if [ -n "$VERBOSE" ]; then echo "  using ro_vol $vol"; fi
    case $vol in
      *:*) opts="$opts --volume $vol:ro" ;;
      *) opts="$opts --volume $vol:$vol:ro" ;;
    esac
  done
  for vol in $rw_vols; do
    if [ -n "$VERBOSE" ]; then echo "  using rw_vol $vol"; fi
    case $vol in
      *:*) opts="$opts --volume $vol" ;;
      *) opts="$opts --volume $vol:$vol" ;;
    esac
  done
}

docker_run_common() {

  ro_vols="$ro_vols /etc/timezone"

  if [ -z "$run_user" ]; then
    run_user=$user
  fi
  if [ -z "$run_group" ]; then
    run_group=$user
  fi
  # NB: "--user $run_user:$run_group" ne marche pas car c'est le /etc/passwd de l'image qui est utilisé
  opts="--user `id -u $run_user`:`id -g $run_group` $opts"

  if [ -n "$VERBOSE" ]; then
    echo '  running as user "'$run_user'" & group "'$run_group'"'
  fi

  if [ -z "$network_driver" ]; then
    network_driver=host
  fi
  opts="--network $network_driver $opts"

  if [ -n "$workdir" ]; then
    opts="$opts --workdir $workdir"
  fi

  if [ "$use_http_proxy_for" = "maven" ]; then
    ro_vols="$ro_vols /opt/dockers/.helpers/various/maven-proxy.univ-paris1.fr-settings.xml:/usr/share/maven/conf/settings.xml"
  fi
  if [ "$use_http_proxy_for" = "java" ]; then
    export JDK_JAVA_OPTIONS="-Dhttp.proxyHost=proxy -Dhttps.proxyHost=proxy -Dhttp.proxyPort=3128 -Dhttps.proxyPort=3128 -Dhttp.nonProxyHosts='localhost|127.*|[::1]|*.univ-paris1.fr|*.pantheonsorbonne.fr'"
    opts="$opts --env JDK_JAVA_OPTIONS"
  fi
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
  docker_run_common

  dyn_dir=/opt/dockers/.run/$container_name/run
  mkdir -p $dyn_dir/etc
  # on fournit un /etc/passwd minimal (nécessaire pour les applis faisant un "getent hosts" de l'utilisateur $user)
  egrep "^$run_user:" /etc/passwd > $dyn_dir/etc/passwd
  egrep "^($run_user|$run_group):" /etc/group > $dyn_dir/etc/group
  ro_vols="$ro_vols $dyn_dir/etc/passwd:/etc/passwd $dyn_dir/etc/group:/etc/group"

  may_configure_rsyslog_and_logrotate
  opts="--log-driver syslog --log-opt tag={{.Name}}:docker:{{.ID}}: $opts"

  opts="--detach --restart always $opts"

  compute_docker_run_opts

  docker run $opts --name $container_name $image "$@" >/dev/null
  
  echo "Created $container_name ($image). Status: "`_container_status $container_name`
}

# variables nécessaires :
# - $image
# variables gérés :
# - $ro_vols : contient les fichiers de l'hote à rendre visible read-only
# - $rw_vols : contient les fichiers de l'hote à rendre visible read-write
# - $network_driver : par défaut le driver "host" est utilisé
# - $workdir : working directory
# - $opts : options diverses
_docker_runOnce() {
  docker_run_common

  if [ -t 0 ]; then
    opts="--interactive --tty --rm $opts"
  fi
  opts="--rm $opts"

  compute_docker_run_opts

  docker run $opts $image "$@"
}

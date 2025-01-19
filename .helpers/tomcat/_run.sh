#!/bin/sh

set -o errexit

[ -n "$port" ] || { echo ".helpers/tomcat/_run.sh is expecting 'port'"; exit 1; }

. .helpers/lib-run--set-vars.sh

if [ -z "$tomcat_logdir" ]; then
    tomcat_logdir=$logdir/tomcat
fi
if [ -z "$remoteIpInternalProxies" ]; then
    remoteIpInternalProxies="127[.]0[.]0[.]1|0:0:0:0:0:0:0:1"
fi
if [ -z "$maxActiveSessionsGoal" ]; then
    # désactivé par défaut
    maxActiveSessionsGoal=-1
fi

rw_vols="$rw_vols $logdir $tomcat_logdir:/usr/local/tomcat/logs"
install -d -o $user -g adm -m 770 $tomcat_logdir

assets=/opt/dockers/.helpers/tomcat/assets

webapps="$webapps $assets/tomcat-monitor.war"
for webapp in $webapps; do
    ro_vols="$ro_vols $webapp:/usr/local/tomcat/webapps/`basename $webapp`"
done

# nos fichiers de conf :
# - server.xml : pour forcer les params http et remote ips
# - tomcat-users.xml : pour forcer le mot de passe ${manager_password}
# - context.xml : pas de WatchedResource
for conf_file in server.xml context.xml tomcat-users.xml; do
  ro_vols="$ro_vols $assets/$conf_file:/usr/local/tomcat/conf/$conf_file"
done

# utilisé dans server.xml
for jar in early-close-http-connector-1.0.0-SNAPSHOT.jar; do
  ro_vols="$ro_vols $assets/$jar:/usr/local/tomcat/lib/$jar"
done

# si on a un mot de passe, on active le tomcat manager. Hors sans reconstruire l'image, la seule façon de l'activer est d'utiliser un fichier de context.xml
if [ -n "$manager_password" ]; then
  ro_vols="$ro_vols $assets/manager-context.xml:/usr/local/tomcat/conf/Catalina/localhost/manager.xml"
fi

install -d -o $user -m 700 /var/lib/sessions-$user
rw_vols="$rw_vols /var/lib/sessions-$user:/var/lib/sessions"


export CATALINA_OPTS="-Dhttp_port=$port -DmaxPostSize=$maxPostSize -DmaxParameterCount=$maxParameterCount -DmaxActiveSessionsGoal=$maxActiveSessionsGoal -Dmanager_password='$manager_password' -DremoteIpInternalProxies='$remoteIpInternalProxies' -Dorg.apache.catalina.session.StandardSession.ACTIVITY_CHECK=true"
opts="$opts --env CATALINA_OPTS"


# Tomcat va libérer le port mais continuer à traiter les reqs en cours, cf https://github.com/UnivParis1/tomcat-early-close-http-connector#readme
# (Tomcat utilise le shutdown hook mechanism de Java qui est déclenché par SIGTERM ou SIGINT ou SIGHUP)
_may_rename_kill_or_rm TERM

_docker_run

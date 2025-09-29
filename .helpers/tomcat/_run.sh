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

if echo $image | grep -q 'tomcat:1[0-9]-'; then
    webapps="$webapps $assets/tomcat10/tomcat-monitor.war"
else
    webapps="$webapps $assets/tomcat-monitor.war"
fi
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


CATALINA_OPTS="$CATALINA_OPTS -Dhttp_port=$port -DmaxHttpHeaderSize=$maxHttpHeaderSize -DmaxPostSize=$maxPostSize -DmaxParameterCount=$maxParameterCount -DmaxActiveSessionsGoal=$maxActiveSessionsGoal -Dmanager_password='$manager_password' -DremoteIpInternalProxies='$remoteIpInternalProxies'"
CATALINA_OPTS="$CATALINA_OPTS -Dorg.apache.catalina.session.StandardSession.ACTIVITY_CHECK=true"
if [ -n "$MaxHeapSize" ]; then
    CATALINA_OPTS="$CATALINA_OPTS -XX:MaxHeapSize=$MaxHeapSize"
fi
export CATALINA_OPTS
opts="$opts --env CATALINA_OPTS"


# Tomcat va libérer le port mais continuer à traiter les reqs en cours, cf https://github.com/UnivParis1/tomcat-early-close-http-connector#readme
# (Tomcat utilise le shutdown hook mechanism de Java qui est déclenché par SIGTERM ou SIGINT ou SIGHUP)
_may_rename_kill_or_rm TERM

if [ -n "$VERBOSE" ]; then
    echo "  using http_proxy $port"
    if [ -n "$maxHttpHeaderSize" ]; then echo "  using maxHttpHeaderSize $maxHttpHeaderSize"; fi
    if [ -n "$maxPostSize" ]; then echo "  using maxPostSize $maxPostSize"; fi
    if [ -n "$maxParameterCount" ]; then echo "  using maxParameterCount $maxParameterCount"; fi
    if [ -n "$maxActiveSessionsGoal" ]; then echo "  using maxActiveSessionsGoal $maxActiveSessionsGoal"; fi
    if [ -n "$manager_password" ]; then echo "  using manager_password <hidden>"; fi
    if [ -n "$remoteIpInternalProxies" ]; then echo "  using remoteIpInternalProxies $remoteIpInternalProxies"; fi
fi

_docker_run

#!/bin/bash

set -e

_build() {
    if [ -n "$want_upgrade" -a -z "$FROM_up1" ]; then
        opts="--pull --no-cache"
        echo "Building image up1-$1 ($opts)"
    else
        opts=""
        echo "Building image up1-$1"
    fi
    set +e
    set -o pipefail
    docker build $opts -t up1-$1 $1/ | tee $1/build.log | grep '^Step '
    if [ $? != 0 ]; then
        cat $1/build.log
        exit 1
    fi
    set -e
    rm -f $1/build.log
}

compute_FROM_up1_var() {
    if [ -e $1/Dockerfile ]; then
        FROM_up1=`perl -lne 'print $1 if /^FROM up1-(\S+)/' $1/Dockerfile`
    else
        FROM_up1=
    fi
}

compute_run_file_var() {
    if [ -e $1/default-run.sh ]; then
        run_file=""
    elif [ -e $1/run.sh ]; then
        run_file=$1/run.sh
    elif [ -n "$FROM_up1" ]; then
        run_file=$FROM_up1/default-run.sh
        if [ ! -e $run_file ]; then
            echo "no $1/run.sh and no $FROM_up1/default-run.sh"
            exit 1
        fi
    else
        echo "no $1/run.sh and no $FROM_up1/default-run.sh"
        exit 1
    fi
}

apply_rights() {
    chmod 700 .git
    chmod 750 $1
    if [ -e $1/IGNORE ]; then
        # l'utilisateur n'existe sûrement pas => pas de chgrp du répertoire, mais le chmod 750 est suffisant
        :
    elif [ -e $1/default-run.sh ]; then
        :
    elif [ -e $1/Dockerfile -o -e $1/run.sh ]; then
        user=${1%--*}
        chgrp $user $1
        for i in Dockerfile etc; do
            if [ -e $1/$i ]; then
                chown -R $user $1/$i
            fi
        done
        if [ ! -e /etc/sudoers.d/dockers-$user ]; then
            cat > /etc/sudoers.d/dockers-$user << EOS
$user ALL=(root) NOPASSWD: /usr/bin/docker ps --filter name=$1
$user ALL=(root) NOPASSWD: /usr/bin/docker exec -it $1 *
$user ALL=(root) NOPASSWD: /usr/bin/docker exec $1 *
$user ALL=(root) NOPASSWD: /opt/dockers/do build $1
$user ALL=(root) NOPASSWD: /opt/dockers/do build-run $1
$user ALL=(root) NOPASSWD: /opt/dockers/do run $1
EOS
        fi
    fi
}

_may_build_pull_run() {
    compute_FROM_up1_var $1
    compute_run_file_var $1
    if [ -n "$want_build" -a -e $1/Dockerfile ]; then
        _build $1
    fi
    if [ -n "$want_pull" -a ! -e $1/Dockerfile ]; then
        # on utilise directement une image externe, sans la modifier.
        # on demande quelle est cette image (nécessite _handle_show_image_name dans run.sh)
        image=`./$run_file --show-image-name`
        if [ -n "$image" ]; then
            echo "docker pull $image"
            docker pull $image
        else
            echo "$run_file n' pas renvoyé d'image"
            exit 1
        fi
    fi
    if [ -n "$want_run" -a -n "$run_file" ]; then
        ./$run_file $1

        # supprimer les anciens images/containers non utilisés
        docker system prune -f >/dev/null
    fi
}

_usage() {
    cat << EOS
usage: 
    $0 { upgrade | build | run | build-run } { --all | <app> ... }
    $0 { run | build-run } --logsf <app>
EOS
    exit 1
}

case $1 in
    build) want_build=1 ;;
    pull) want_pull=1 ;;
    run) want_run=1 ;;
    build-run) want_build=1; want_run=1 ;;
    run-tail) want_build=1; want_run=1 ;;
    upgrade) want_build=1; want_pull=1; want_run=1; want_upgrade=1 ;;
    rights) ;;
    *) _usage ;;
esac
shift

if [ "$1" = "--logsf" ]; then
    want_logsf=1
    shift
fi

if [ "$1" = "--all" ]; then
    apps=*/
elif [ -n "$1" ]; then
    apps=$@
else
    _usage
fi

cd /opt/dockers

for app in $apps; do
    # remove trailing slash
    app=${app%/}

    apply_rights $app

    if [ -e $app/IGNORE ]; then
        echo "$app ignoré (supprimer le fichier $app/IGNORE pour réactiver)"
        continue
    fi

    compute_FROM_up1_var $app
    if [ -z "$FROM_up1" ]; then
        # d'abord les applis/images sans parents up1-xxx
        apps_="$app $apps_ "
    else
        apps_="$apps_ $app"
    fi
done

for app in $apps_; do
    _may_build_pull_run $app
done
if [ -n "$want_logsf" ]; then
    exec docker logs -f $app
fi

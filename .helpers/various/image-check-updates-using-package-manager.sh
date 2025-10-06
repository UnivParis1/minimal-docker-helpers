if [ -x /usr/bin/apt-get ]; then
    /usr/bin/apt-get -qq update && /usr/bin/apt list --upgradable 2>/dev/null | sed -n 's!\([^/]*\)/[^ ]* \([^ ]*\) [^ ]* \[upgradable from: \([^]]*\)\]!\1 \3 -> \2!p'
elif [ -x /usr/bin/yum ]; then
    /usr/bin/yum --quiet check-update | sed -n 's/[.]\(x86_64\|noarch\)[ ]*\([^ ]*\).*/ _ -> \2/p'
elif [ -x /sbin/apk ]; then
    /sbin/apk --no-cache --simulate upgrade 2>/dev/null | sed -n 's/[^ ]* Upgrading //p'
else 
    echo no package manager for Linux distribution `sed -n 's/^NAME=//p' /etc/os-release`
fi


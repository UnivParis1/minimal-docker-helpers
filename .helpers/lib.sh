_container_exists() { 
    docker inspect --format ' ' $1 >/dev/null 2>&1
}
_container_status() { 
    docker inspect --format '{{.State.Status}}' $1 2>/dev/null
}

#!/usr/bin/perl -w
use strict;
use List::Util qw(first);
#use Data::Dumper;

sub read_file { 
    my ($f) = @_;
    open(my $F, '<', $f) or die "failed to read $f: $?\n";
    wantarray() ? <$F> : join('', <$F>);
}
sub write_file { 
    my ($f, @l) = @_;
    open(my $F, '>', $f) or die "failed to write $f: $?\n";
    print $F $_ foreach @l;
}
sub write_tempfile {
    require File::Temp;
    my ($F, $file) = File::Temp::tempfile();
    print $F $_ foreach @_;
    $file
}
sub rm_rf {
    my ($f) = @_;
    if (-d $f) {
        rm_rf($_) foreach glob("$f/*");
        rmdir $f or die "rmdir $f failed";
    } elsif (-e $f) {
        unlink $f or die "rm $f failed";
    }
}
sub sys {
    system(@_) == 0 or die "@_ failed";
}
sub may_symlink {
    my ($link, $f, $cb) = @_;
    if (! -e $f) {
        symlink($link, $f) or die "symlink failed: $?";
        $cb->($link, $f);
    }
}
sub difference {
    my ($a, $to_remove) = @_;
    my %to_remove = map { $_ => 1 } @$to_remove;
    grep { !$to_remove{$_} } @$a;
}

my %c = (
  GREEN => "\033[0;32m",
  YELLOW => "\033[0;33m",
  RED => "\033[0;31m",
  GRAY => "\033[0;90m",
  NC => "\033[0m", # No Color
);

my %opts;

sub log_ {
    my ($msg) = @_;
    $opts{verbose} and print STDERR "$msg\n";
}

sub get_FROM {
    my ($dockerfile) = @_;
    my ($image) = read_file($dockerfile) =~ /^FROM (\S+)/m or die "$dockerfile has no FROM";
    $image
}
sub FROM_to_name {
    my ($image) = @_;
    my ($name)= $image =~ /^up1-(.*)/ or return;
    $name =~ /^[\w:.-]+$/ or die "invalid FROM « $image »";
    $name
}

sub parse_size {
    my ($Size) = @_;
    $Size =~ s/GB$/ * 1024*1024*1024/;
    $Size =~ s/MB$/ * 1024*1024/;
    $Size =~ s/kB$/ * 1024/;
    $Size =~ s/B$//;
    eval $Size
}

sub may_get_image {
    my ($env_file) = @_;
    -e $env_file && read_file($env_file) =~ m!^image=([\w:./-]+)$!m && $1
}

sub image_exists { 
    system("docker inspect --format ' ' $_[0] >/dev/null 2>&1") == 0
}

sub image_id { 
    my $s = `docker inspect --format '{{.ID}}' $_[0] 2>/dev/null`;
    chomp $s;
    $s
}

# returns  containers which should be re-created with the new image
sub old_containers {
    # when container image is sha256:xxx it means the image is no more the latest
    map { /(\S+) sha256:/ ? $1 : () } `docker container ls --no-trunc --format '{{.Names}} {{.Image}}'`
}

sub image_to_containers {
    my %i2c;
    foreach (`docker container ls --no-trunc --format '{{.Image}} {{.Names}}'`) {
        my ($i, $c) = split;
        push @{$i2c{$i}}, $c;
    }
    \%i2c
}

# NB: returns either up1-xxx or repo:version or sha256:xxx
sub images_in_use {
    map { chomp; $_ } `docker container ls --no-trunc --format '{{.Image}}'`
}

sub old_or_missing_images {
    my ($appsv, $isRunOnce) = @_;
    my %name2parents = map {
        my ($name, @parents) = split;
        $name =~ s/^up1-// or die;
        ($name => \@parents)
    } `/opt/dockers/.helpers/docker-images-parents`;

    map {
        my $name = $_->{name};
        if (my $parent = $_->{$isRunOnce ? 'FROM_runOnce' : 'FROM'}) {
            my $current_parents = $name2parents{$name};
            !$current_parents ? ($name => 'missing') :
                $parent && !(List::Util::any { $_ eq $parent } @$current_parents) ? ($name => 'old') : ()
        } else {
            ()
        }
    } @$appsv
}

sub compute_app_vars {
    my ($app) = @_;
    my %v = (name => $app);

    $v{image} = may_get_image("$app/run.env");
    $v{image_runOnce} = may_get_image("$app/runOnce.env");
    if ($v{image}) {
        $v{image_up1} = FROM_to_name($v{image});
    }
    if ($v{image_runOnce}) {
        $v{image_runOnce_up1} = FROM_to_name($v{image_runOnce});
    }

    if (-e "$app/Dockerfile") {
        $v{FROM} = get_FROM("$app/Dockerfile");
        $v{FROM_up1} = FROM_to_name($v{FROM});
    }
    if (-e "$app/runOnce.dockerfile") {
        $v{FROM_runOnce} = get_FROM("$app/runOnce.dockerfile");
        $v{FROM_runOnce_up1} = FROM_to_name($v{FROM_runOnce});
    }

    if ( -e "$app/default-run.sh" ) {
        $v{run_file} = "";
    } elsif (-e "$app/run.sh") {
        $v{run_file} = "$app/run.sh";
    } elsif ($v{FROM_up1}) {
        $v{run_file} = "$v{FROM_up1}/default-run.sh";
        -e $v{run_file} or die("no $app/run.sh and no $v{run_file}\n");
    } elsif ($v{image_up1}) {
        $v{run_file} = "$v{image_up1}/default-run.sh";
        -e $v{run_file} or die("no $app/run.sh and no $v{run_file}\n");
    } elsif ($v{FROM}) {
        die("no $app/run.sh and no default-run.sh from parent image (Dockerfile FROM)\n");
    } elsif ($v{image}) {
        die("no $app/run.sh and no default-run.sh from parent image (image=xxx in run.env)\n");
    } elsif (-e "$app/run.env") {
        die("no $app/run.sh\n");
    }

    if ( -e "$app/default-runOnce.sh" ) {
        $v{runOnce_file} = "";
    } elsif (-e "$app/runOnce.sh") {
        $v{runOnce_file} = "$app/runOnce.sh";
    } elsif ($v{FROM_runOnce_up1}) {
        $v{runOnce_file} = "$v{FROM_runOnce_up1}/default-runOnce.sh";
        $v{runOnce_file} = ".helpers/_runOnce.sh" if ! -e $v{runOnce_file};
    } elsif ($v{image_runOnce_up1}) {
        $v{runOnce_file} = "$v{image_runOnce_up1}/default-runOnce.sh";
        $v{runOnce_file} = ".helpers/_runOnce.sh" if ! -e $v{runOnce_file};
    } elsif (-e "$app/runOnce.env") {
        $v{runOnce_file} = ".helpers/_runOnce.sh";
    }

    \%v
}

sub all_appsv {
    [ map {
       # remove trailing slash
       s!/$!!;
       compute_app_vars($_)
    } glob("*/") ]
}

my @user_files = qw(Dockerfile runOnce.dockerfile run.env runOnce.env);

sub apply_rights {
    my ($app) = @_;
    chmod(0700, '.git') or die "chmod .git failed";
    chmod(0750, $app) or die "chmod $app failed";

    if (-e "$app/IGNORE") {
        # l'utilisateur n'existe sûrement pas => pas de chgrp du répertoire, mais le chmod 750 est suffisant
    } elsif (-e "$app/default-run.sh") {
    } elsif (-e "$app/run.sh" && read_file("$app/run.sh") =~ /^\s*user=root\s*$/m) {
        # l'utilisateur n'existe pas => pas de chgrp du répertoire, mais le chmod 750 est suffisant
    } elsif (grep { -e "$app/$_" } @user_files) {
        my $user = $app =~ /(.*)--/ && $1 || $app;
        my $uid = getpwnam($user) or die "app $app requires user $user\n";
        my $gid = getgrnam($user);
        chown(0, $gid, $app) or die "chgrp $app failed";
        -e $_ and chown($uid, $gid, $_) foreach map { "$app/$_" } @user_files;
        my $sudoer_file = "/etc/sudoers.d/dockers-$app";
        if (! -e $sudoer_file) {
            write_file($sudoer_file, <<EOS);
$user ALL=(root) NOPASSWD: /opt/dockers/do build $app
$user ALL=(root) NOPASSWD: /opt/dockers/do build-run $app
$user ALL=(root) NOPASSWD: /opt/dockers/do build-runOnce $app
$user ALL=(root) NOPASSWD: /opt/dockers/do build-runOnce $app *
$user ALL=(root) NOPASSWD: /opt/dockers/do run $app
$user ALL=(root) NOPASSWD: /opt/dockers/do run --logsf $app
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce $app
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce $app *
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce --quiet $app *
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce-run $app
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce-run $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker ps --filter name=$app
$user ALL=(root) NOPASSWD: /usr/bin/docker exec -it $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker exec -i $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker exec $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker logs $app
$user ALL=(root) NOPASSWD: /usr/bin/docker logs $app *
$user ALL=(root) NOPASSWD: /usr/bin/cat /var/log/docker/$app.log
$user ALL=(root) NOPASSWD: /usr/bin/tail -f /var/log/docker/$app.log
EOS
        }
    }

    may_symlink('/opt/dockers/.helpers/various/git-hook-apply-rights', '.git/hooks/post-rewrite',
        sub { "Installing $_[0] in $_[1]\n" });
    may_symlink('/opt/dockers/.helpers/various/bash_autocomplete', '/etc/bash_completion.d/opt_dockers_do',
        sub { "Installing $_[0] in $_[1]\n" });
}

sub check_updates_using_package_manager {
    my ($app2appsv, $appsv) = @_;

    my %images;
    my $may_add = sub {
        my ($appv, $isRunOnce) = @_;
        my $app = $appv->{name};
        my $image = $isRunOnce ? "up1-once-$app" : "up1-$app";
        my $e = $images{$image};
        if (!$e) {
            my $cache_buster_dir = cache_buster_dir_rec($app2appsv, $appv, $isRunOnce) or return;
            $images{$image} ||= $e = { apps => [], cache_buster_file => "$cache_buster_dir/$image" };
        }
        push @{$e->{apps}}, $isRunOnce ? "$app(runOnce)" : $app;
    };
    foreach my $appv (@$appsv) {
        $may_add->($appv, 0) if $appv->{FROM};
        $may_add->($appv, 1) if $appv->{FROM_runOnce};
    }
    foreach my $image (sort keys %images) {
        my $e = $images{$image};
        my $apps = join(",", @{$e->{apps}});
        log_("$c{GRAY}Checking updates using package manager in image $image (used by $apps) $c{NC}");
        if (my $updates = `cat /opt/dockers/.helpers/various/image-check-updates-using-package-manager.sh | docker run --rm -i --env-file /opt/dockers/.helpers/various/proxy.univ-paris1.fr.env --entrypoint=sh $image`) {
            print "Found package manager updates for $image (used by $apps)\n";
            write_file($e->{cache_buster_file}, $updates);
            print "$c{YELLOW}$updates$c{NC}\n" if !$opts{quiet};
        }
    }


}

sub get_parent_image {
    my ($app2appsv, $appv, $isRunOnce) = @_;

    while (1) {
        my $image = $appv->{$isRunOnce ? 'image_runOnce' : 'image'} || $appv->{$isRunOnce ? 'FROM_runOnce' : 'FROM'} or return;
        if (my $parent = FROM_to_name($image)) {
            $isRunOnce = 0; # we are reusing non runOnce image 
            $appv = $app2appsv->{$parent};
        } else {
            return $image;
        }
    }
}

sub check_image_updates {
    my ($app2appsv, $appsv) = @_;

    my %images;
    foreach my $appv (@$appsv) {
        if (my $image = get_parent_image($app2appsv, $appv, 0)) {
            push @{$images{$image}}, $appv->{name};
        }
        if (my $image = get_parent_image($app2appsv, $appv, 1)) {
            push @{$images{$image}}, "$appv->{name}(runOnce)";
        }
    }

    foreach my $image (sort keys %images) {
        if ($image =~ /\d+[.]\d+[.]\d+$/) {
            # no need to check such precise images, they do not get updates
            next;
        }
        if ($image =~ /^debian:/) {
            # no need to check debian based distro: everything can be upgraded via "apt upgrade" which we always do
            next;
        }
        my $apps = join(",", @{$images{$image}});
        log_("$c{GRAY}Checking docker.io registry for $image update (used by $apps)$c{NC}");
        
        my ($current) = `docker inspect --format '{{index .RepoDigests 0}}' $image` =~ /@(.*)/;
        
        my ($repo, $tag) = split(":", $image);
        $repo = "library/$repo" if $repo !~ m!/!;
        my ($new) = `/opt/dockers/.helpers/get-image-info-from-docker.io-registry digest $repo $tag` =~ /(\S+)/;

        if (!$new) {
            print "$c{RED}ERROR getting latest image $image$c{NC}\n";
        } elsif ($new ne $current) {
            print "Found docker image update for $image (used by $apps)\n";

            # Display a diff of Dockerfile commands (from "docker history")
            # useful to show change of versions. eg:
            # -ADD alpine-minirootfs-3.22.1-x86_64.tar.gz /
            # +ADD alpine-minirootfs-3.22.2-x86_64.tar.gz /
            # or
            # -ENV TOMCAT_VERSION=10.1.47
            # +ENV TOMCAT_VERSION=10.1.48
            if (!$opts{quiet}) {
                # to have a shorter diff, ignore RUN lines (hopefully package have a VAR or ADD). tested on maven:3-eclipse-temurin-17-alpine
                sub simplify {
                    grep { !/^RUN / } @_
                }
                require File::Temp;
                my $old = write_tempfile(simplify(`docker history --no-trunc --format '{{.CreatedBy}}' $image | sed 's/#.*//'`));
                my $new = write_tempfile(simplify(`/opt/dockers/.helpers/get-image-info-from-docker.io-registry config $repo $tag | jq -r '.history[] | .created_by' | tac | sed 's/#.*//'`));
                
                my $color = $opts{no_color} ? 'never' : 'always';
                my $diff = `diff --ignore-all-space --color=$color --palette='de=90:ad=33' -U0 $old $new | tail -n +4`;
                unlink $old;
                unlink $new;
                if ($diff) {
                    print "$diff\n";
                } elsif (my $updates = 
                    # build command did not change, it must be a package change:
                    `cat /opt/dockers/.helpers/various/image-check-updates-using-package-manager.sh | docker run --rm -i --env-file /opt/dockers/.helpers/various/proxy.univ-paris1.fr.env --entrypoint=sh $image`) {
                    print "$c{YELLOW}$updates$c{NC}\n";
                }
            } 
        } else {
            log_("$c{GRAY}=> $image is up-to-date$c{NC}");
        }
    }
}

sub check_updates_many {
    my ($appsv) = @_;

    if ($opts{verbose} && ! -e "/etc/cron.d/opt_dockers_do__check-updates") {
        print STDERR "$c{GRAY}Pour installer le cron check-updates, lancer : ln -s /opt/dockers/.helpers/various/check-updates-cron /etc/cron.d/opt_dockers_do__check-updates$c{NC}\n";
    }

    my %app2appsv = map { $_->{name} => $_ } @{all_appsv()};
    check_updates_using_package_manager(\%app2appsv, $appsv);
    check_image_updates(\%app2appsv, $appsv);
}

sub purge_exited_containers {
    my ($all_appsv) = @_;

    my @exited = map { chomp; $_ } `docker container ls --filter 'status=exited' --format '{{.Names}}'`;
    # do not remove known containers, only remove unknown ones (mostly containers which were renamed old-xxx)
    if (my $unknown_exited_containers = join(" ", difference(\@exited, [ map { $_->{name} } @$all_appsv ]))) {
        log_("Removing old containers: $unknown_exited_containers");
        sys("docker container rm $unknown_exited_containers >/dev/null");
    }
}

sub purge_unused_images {
    my ($all_appsv) = @_;

    my %images_in_use = map { $_ => 1 } images_in_use();
    my %expected_images = map { $_ => 1 } grep { $_ } map {
        my $for_run = $_->{image} || $_->{FROM};
        my $for_runOnce = $_->{image_runOnce} || $_->{FROM_runOnce};
        (
            $for_run ? ($for_run, "up1-$_->{name}") : (),
            $for_runOnce ? ($for_runOnce, "up1-once-$_->{name}") : (),
        )
    } @$all_appsv;

    my %unused_images = map { 
        s/:latest$//; 
        my ($id, $name) = split; 
        if ($images_in_use{$id} || $images_in_use{$name}) {
            # in use!
            ()
        } elsif ($expected_images{$name}) {
            # either : 
            # - will be useful for build or run
            # - will be useful for runOnce
            ()
        } else {
            $id => $name
        }
    } `docker image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'`;

    my @removed = map {
        system("docker image rm $_ >/dev/null 2>&1") == 0 ? $unused_images{$_} : ()
    } keys %unused_images;
    log_("Removed old/unused images: " . join(" ", sort @removed)) if @removed;
    @removed
}

sub purge {
    my ($all_appsv) = @_;    
    purge_exited_containers($all_appsv);
    while (purge_unused_images($all_appsv)) {}
}

sub may_clean_and_tag_image_prev {
    my ($image, $image_prev, $prev_id) = @_;

    if (!$prev_id) {
        # there was no main tag, nothing to do
    } elsif (system("docker image remove $prev_id >/dev/null 2>&1") == 0) {
        # the previous image was unused, nothing to do
    } else {               
        my $current_prev = image_id($image_prev);
        if ($current_prev eq $prev_id) {
            # the previous main tag was also prev tag, weird but no a pb
        } else {
            if ($current_prev) {
                # NB: we use image id instead of tag, since local build tags can be removed even if child images
                if (system("docker image remove $current_prev >/dev/null 2>&1") == 0) {
                    log_("removed unused $image_prev");
                } else {
                    log_("saving previous prev image as ${image_prev}2");
                    sys("docker tag $current_prev ${image_prev}2");
                    print "$c{RED}Too many old $image (${image_prev}2, $image_prev), you must upgrade things!!$c{NC}\n";
                }
            }
            log_("saving previous image as $image_prev");
            sys("docker tag $prev_id $image_prev");
        }
    }
}

sub cache_buster_dir {
    my ($app, $isRunOnce) = @_;

    my $dockerfile = $isRunOnce ? "runOnce.dockerfile" : "Dockerfile";
    -f "$app/$dockerfile" or return undef;

    my $cache_buster_dir = ".$dockerfile.cache-buster";   
    read_file("$app/$dockerfile") =~ /^COPY \Q$cache_buster_dir/m or return undef;
    
    "$app/$cache_buster_dir"
}

# on cherche le plus proche parent ayant "COPY .Dockerfile.cache-buster /root/" (normalement un seul parent à cet instruction)
sub cache_buster_dir_rec {
    my ($app2appsv, $appv, $isRunOnce) = @_;

    while (1) {
        my $parent_image = $appv->{$isRunOnce ? 'FROM_runOnce' : 'FROM'} or return;

        if (my $dir = cache_buster_dir($appv->{name}, $isRunOnce)) {
            return $dir;
        }

        my $parent = FROM_to_name($parent_image) or return;
        $isRunOnce = 0; # we are reusing non runOnce image 
        $appv = $app2appsv->{$parent};
    }
}

sub build {
    my ($app, $isRunOnce) = @_;
    my $image = $isRunOnce ? "up1-once-$app" : "up1-$app";

    my $prev_id = image_id($image);

    if (my $cache_buster_dir = cache_buster_dir($app, $isRunOnce)) {
        if (! -d $cache_buster_dir) {
            log_("creating $cache_buster_dir");
            mkdir $cache_buster_dir;
        }
    }

    my $opts = $isRunOnce ? "-f $app/runOnce.dockerfile" : '';
    my $cmd = "docker build $opts -t $image $app/";
    log_($cmd);
    open(my $F, "$cmd |");
    my @may_show = "$c{YELLOW}Building image $image$c{NC}\n";
    my $out;
    my $status = 'from_cache';
    while (<$F>) {
        push @may_show, $_ if /^Step/;
        if (/^\Q ---> Running in /) {
            $status = 'built';
            # afficher une information de progression, mais pas tout, et uniquement si pas de cache
            print foreach @may_show;
            @may_show = ();
        }
        $out .= $_;
    }
    close($F) or do {
        print $out;
        exit 1;
    };
    print "\n" if $status eq 'built';

    if ($status ne 'from_cache') {
        # ensure old image does not appear as <none>:<none> in "docker images"
        may_clean_and_tag_image_prev($image, "$image:prev", $prev_id);
    }

    $status
}

my %built;
sub may_build_many {
    my ($appsv, $isRunOnce) = @_;
    my %todo = map { $_->{name} => $_ } grep {
        -e ($isRunOnce ? "$_->{name}/runOnce.dockerfile" : "$_->{name}/Dockerfile")
    } @$appsv;

    my %previously_built = map { /^up1-(.*):latest/ ? ($1 => 1) : () } `docker image ls --format '{{.Repository}}:{{.Tag}}'`;

    my $all_appsv;

    my $rec; $rec = sub {
        my ($app, $child) = @_;

        my $appv = delete $todo{$app};
        if ($built{"$app $isRunOnce"}) {
            # rien à faire :-)
            return
        }        

        if (!$appv) {
            $previously_built{$app} or die "Il faut builder $app pour pouvoir builder $child\n";
            return;
        };

        if (my $parent = $appv->{$isRunOnce ? 'FROM_runOnce_up1' : 'FROM_up1'}) {
            my $parent_modified = $rec->($parent, $app);
        }

        purge($all_appsv ||= all_appsv()); # purge before is needed to ensure unused $image:prev is removed
        $built{"$app $isRunOnce"} = build($app, $isRunOnce);

        $built{"$app $isRunOnce"}
    };

    while (%todo) {
        my $app = (sort keys %todo)[0];
        $rec->($app);
    }

}

my %pulled;
sub may_pull {
    my ($image, $cache_buster_dir) = @_;
    if ($image && $image !~ /^up1-/ && !$pulled{$image}) {
        # ce n'est pas une image locale, on demande la dernière version (pour les rolling tags)

        my $prev_id = image_id($image);

        print STDERR "$c{YELLOW}docker pull $image$c{NC}\n";
        sys("docker", "pull", $image);
        print "\n";
        $pulled{$image} = 1;

        my $new_id = image_id($image);
        if ($new_id ne $prev_id) {
            may_clean_and_tag_image_prev($image, "$image-prev", $prev_id);
            rm_rf($cache_buster_dir) if $cache_buster_dir; # ce répertoire n'est plus nécessaire car le cache build est invalidé par le chgt de FROM
        }
    }
}

sub pull {
    my ($appv) = @_;
    may_pull($appv->{image});
    may_pull($appv->{image_runOnce}) if !$opts{only_run};
    may_pull($appv->{FROM},         cache_buster_dir($appv->{name}, 0));
    may_pull($appv->{FROM_runOnce}, cache_buster_dir($appv->{name}, 1)) if !$opts{only_run};
}

sub run {
    my ($appv) = @_;
    log_(qq(Running "VERBOSE=1 ./$appv->{run_file} $appv->{name}" :));
    $ENV{VERBOSE} = $opts{verbose};
    sys("./$appv->{run_file}", $appv->{name});
}

sub run_once {
    my ($appv) = @_;
    $appv->{runOnce_file} or die("ERROR: no runOnce.sh nor runOnce.env\n");
    log_(qq(Running "container_name=$appv->{name} $appv->{runOnce_file} @ARGV"));
    $ENV{container_name} = $appv->{name};
    $ENV{QUIET} = $opts{quiet};
    $ENV{VERBOSE} = $opts{verbose};
    sys($appv->{runOnce_file}, @ARGV);

}

sub may_run_many {
    my ($appsv) = @_;
    my @l = grep { $_->{run_file} } @$appsv;
    if ($opts{if_old}) {
        my %old_containers = map { $_ => 1 } old_containers();
        @l = grep { $old_containers{$_->{name}} } @l;
        @l or print "$c{YELLOW}Aucun conteneurs à re-créer$c{NC}\n";
    }

    my $all_appsv = $opts{all} ? $appsv : all_appsv();

    foreach (@l) {
        run($_);
        purge($all_appsv);
    }
}

sub get_states {
    +{  }
}

sub ps {
    my ($app, $states, $old_containers, $old_or_missing_images) = @_;
    my $state = $states->{$app} || 'missing';
    my $old = $old_containers->{$app} ? " $c{YELLOW}(containeur needs rerun)$c{NC}" : '';
    my $image_state = $old_or_missing_images->{$app} ? " $c{YELLOW}(image is $old_or_missing_images->{$app})$c{NC}" : '';
    if ($state eq 'running') {
        if (!$opts{quiet} || $old || $image_state) {
            printf "%s $c{GREEN}%s$c{NC}%s\n", $app, $state, $old . $image_state;
        }
    } else {
        printf "%s $c{RED}%s$c{NC}\n", $app, uc($state);
    }
}

sub ps_many {
    my ($appsv) = @_;
    my %states = map { split } `docker container ls -a --format "{{.Names}} {{.State}}"`;
    my %old_containers = map { $_ => 1 } old_containers();
    my %old_or_missing_images = $opts{check_image_old} ? old_or_missing_images($appsv) : ();
    ps($_->{name}, \%states, \%old_containers, \%old_or_missing_images) foreach grep { $_->{run_file} } @$appsv;
}

sub stop_rm {
    my ($appsv) = @_;
    foreach my $appv (@$appsv) {
        my $app = $appv->{name};
        my $state = `docker inspect --format '{{.State.Status}}' $app 2>/dev/null`;
        chomp($state);
        if ($state eq 'exited') {
            print "$app is already stopped, removing container\n";
        } elsif (!$state) {
            die "Container $app does not exist\n";
        }
        if ($state eq 'running') {
            print "Stopping $state $app\n";
            sys("docker stop $app >/dev/null");
        }
        sys("docker rm $app >/dev/null");
        if ($state eq 'running') {
            print "$app stopped and removed\n";
        }
    }
}

sub images {
    my ($appsv) = @_;

    my $id_or_name_to_containers = image_to_containers();

    my %expected_images;
    foreach (@$appsv) {
        $_->{FROM} and $expected_images{"up1-$_->{name}"}{parent} = $_->{FROM};
        $_->{FROM_runOnce} and $expected_images{"up1-once-$_->{name}"}{parent} = $_->{FROM_runOnce};
        $_->{image_runOnce} and push @{$expected_images{$_->{image_runOnce}}{containers_once}}, "once-$_->{name}";
    }

    my %images;
    foreach (`docker image ls --no-trunc --format '{{.ID}}\t{{.CreatedSince}}\t{{.Size}}\t{{.Repository}}:{{.Tag}}'`) {
        chomp; 
        my ($id, $createdSince, $size, $name) = split "\t";
        $name =~ s/:latest//; # normalize

        my $h = {
            id => $id,
            CreatedSince => $createdSince,
            size => int(parse_size($size) / 1024/1024) . "MB",
            name => $name,
            names => [$name],
        };


        my $more_h = delete $expected_images{$name} || {};
        $h = { %$h, %$more_h };

        $h->{containers} = $id_or_name_to_containers->{$id} || $id_or_name_to_containers->{$name};

        if (my ($isRunOnce, $app) = $name =~ /^up1-(once-)?([^:]*)/) {
            my ($appv) = grep { $_->{name} eq $app } @$appsv or warn("$c{RED}unknown image $name$c{NC}\n"), next;
            $h->{app} = $app;
        }
        if ($images{$id}) {
            $images{$id}{names} = $h->{names} = [ $h->{name}, @{$images{$id}{names}} ];
            if (length($images{$id}{name}) < length($h->{name})) {
                next;
            }
        } 
        $images{$id} = $h ;
    }
    foreach my $id (keys %images) {
        my $h = $images{$id};
        if ($h->{name} =~ /^up1-/) {
            my @history = map { chomp; [split] } `docker history --no-trunc --format '{{.ID}} {{.Size}}' $id`;
            my @ids = map { $_->[0] } @history;
            my @parents = grep { $_ && $_->{name} ne $h->{name} } map { $images{$_} } @ids;
            my $parent = $parents[0];
            if (!$parent) {
                $h->{parent} .= " $c{YELLOW}(old)$c{NC}";
            } else {
                push @{$_->{children}}, $h->{name} foreach $parent;
                $h->{parent} = $parent->{name};
                $h->{parent} =~ s/([:-]prev\d*)?$/$c{YELLOW} . ($1||'') . $c{NC}/e;
                my $delta = 0;
                foreach (@history) {
                    last if $_->[0] eq $parent->{id};
                    $delta += parse_size($_->[1]);
                }
                $h->{size} = "+" . int($delta / 1024/1024) . "MB";
            }
        }
    }

    $images{$_} = { name => $_, missing => 1, %{$expected_images{$_}} } foreach keys %expected_images;

    my $format = "%-45s %30s %10s   %-40s %-40s %s\n";
    printf $format, "NAME$c{YELLOW}$c{NC}", 'CREATED' . $c{RED}.$c{NC}, 'SIZE', "PARENT $c{YELLOW}$c{NC}", 'CONTAINERS', 'ENFANTS';
    foreach my $h (sort { $a->{name} cmp $b->{name} } values %images) {
        $h->{name} =~ s/([:-]prev\d*)?$/$c{YELLOW} . ($1||'') . $c{NC}/e;
        printf $format, 
            $h->{name}, 
            $h->{missing} ? "$c{RED}missing$c{NC}" : $h->{CreatedSince} . $c{RED}.$c{NC}, 
            $h->{size} || '', 
            $h->{parent} || " $c{YELLOW}$c{NC}", 
            join(', ', @{$h->{containers_once} || []}) . ' ' .
              ($h->{containers} ? "$c{GREEN}" . join(', ', @{$h->{containers}}) . "$c{NC}" :
                $h->{children} || $h->{missing} || $h->{containers_once} || $h->{name} =~ /^up1-once-/ ? '' : "$c{YELLOW}unused$c{NC}"), 
            $c{GRAY} . join(', ', @{$h->{children} || []}) . $c{NC};
    }
}

sub usage {
    die(<<"EOS");
usage: 
    $0 upgrade [--verbose] [<app> ...]
    $0 pull [--only-run] { --all | <app> ... }
    $0 build [--only-run] [--only-runOnce] [--verbose] { --all | <app> ... }
    $0 { run | build-run } [--if-old] [--verbose] [--logsf] { --all | <app> ... }
    $0 { runOnce | build-runOnce | runOnce-run } [--quiet] <app> [--cd <dir|subdir>] <args...>
    $0 purge
    $0 images
    $0 check-updates [--quiet] [--verbose] [--random-delay=<min>m] { --all | <app> ... }
    $0 ps [--quiet] [--check-image-old] [<app> ... ]
    $0 rights [--quiet] { --all | <app> ... }
    $0 stop-rm [--quiet] { --all | <app> ... }
EOS
}

if ($> != 0 ) {
  die("Re-lancer avec sudo\n");
}

my ($want_upgrade, $want_check_updates, $want_purge, $want_build, $want_pull, $want_run, $want_build_runOnce, $want_runOnce, $want_ps, $want_images, $want_stop_rm);
my %actions = (
    'build' => sub { $want_build = $want_build_runOnce = 1 },
    'check-updates' => sub { $want_check_updates = 1 },
    'purge' => sub { $want_purge = 1 },
    'images' => sub { $want_images = 1 },
    'pull' => sub { $want_pull = $want_ps = $opts{check_image_old} = 1 },
    'run' => sub { $want_run = 1 },
    'build-run' => sub { $want_build = $want_run = 1 },
    'upgrade' => sub { $want_build = $want_build_runOnce = $want_pull = $want_run = $want_upgrade = $opts{if_old} = 1 },
    'runOnce' => sub { $want_runOnce = 1 },
    'build-runOnce' => sub { $want_build_runOnce = $want_runOnce = 1 },
    'runOnce-run' => sub { $want_runOnce = $want_run = 1 },
    'rights' => sub { },
    'ps' => sub { $want_ps=1 },
    'stop-rm' => sub { $want_stop_rm = 1 },
);
my $action = shift;
my $set_opts = $actions{$action || ''} or usage();
$set_opts->();

chdir '/opt/dockers' or die;

while (1) {
    @ARGV or last;
    my ($opt, $value);
    if (($opt) = grep { $ARGV[0] eq $_ } "--only-run", "--only-runOnce", "--logsf", "--quiet", "--verbose", "--if-old", "--check-image-old", "--no-color") {
        shift;
        $opt =~ s/^--//;
        $opt =~ s/-/_/g;
        $opts{$opt} = 1;
    } elsif (($opt, $value) = $ARGV[0] =~ /^--(random-delay)=(\S+)$/) {
        shift;
        $opt =~ s/-/_/g;
        $opts{$opt} = $value;
    } else {
        last;
    }
}
if ($opts{no_color}) {
    $c{$_} = '' foreach keys %c;
}

my @apps;
if (@ARGV ? $ARGV[0] eq "--all" : $want_ps || $want_upgrade || $want_purge || $want_images) {
    @apps = glob("*/");
    $opts{all} = 1;
} elsif (@ARGV) {
    if ($want_runOnce) {
        @apps = shift;
    } else {
        @apps = @ARGV;
    }
} else {
    usage();
}

@apps = map {
    # remove trailing slash
    s!/$!!;
    $_ 
} @apps;

-d $_ or die "invalid app $_" foreach @apps;

apply_rights($_) foreach @apps;

@apps = grep {
    my $ignore = -e "$_/IGNORE" || -e "$_/SYSTEMD";
    if ($ignore) {
        $opts{quiet} or print STDERR "$c{GRAY}$_ ignoré (supprimer le fichier $_/IGNORE pour réactiver)$c{NC}\n";
    }
    !$ignore
} @apps;

my @appsv = map { compute_app_vars($_) } @apps;

if ($opts{random_delay}) {
    my $delay = $opts{random_delay};
    $delay = $1 * 60 if $delay =~ /(\d+)m$/;
    sleep(rand($delay));
}
if ($want_purge) {
    $opts{verbose} = 1;
    purge([@appsv]);
}
if ($want_check_updates) {
    check_updates_many([@appsv]);
}
if ($want_pull) {
    pull($_) foreach @appsv;
}
if ($want_build && !$opts{only_runOnce}) {
    may_build_many([@appsv], '') ;
    print STDERR "$c{YELLOW}Aucune image modifiée$c{NC}\n\n" if !grep { $built{$_} ne 'from_cache' } keys %built;
}
if ($want_build_runOnce && !$opts{only_run}) {
    may_build_many([@appsv], 'runOnce');
}
if ($want_runOnce) {
    run_once($appsv[0]);
}
if ($want_run) {
    may_run_many([@appsv]);
}
if ($want_ps) {
    ps_many([@appsv]);
}
if ($want_images) {
    images([@appsv]);
}
if ($want_stop_rm) {
    stop_rm([@appsv]);
}
if ($opts{logsf}) {
    exec('docker', 'logs', '-f', $apps[0]);
}

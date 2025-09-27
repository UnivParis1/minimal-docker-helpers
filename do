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

my $GREEN = "\033[0;32m";
my $YELLOW = "\033[0;33m";
my $RED = "\033[0;31m";
my $NC = "\033[0m"; # No Color

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
        -e $v{run_file} or die("no $app/run.sh and no $v{FROM_up1}/default-run.sh\n");
    } elsif (-e "$app/run.env" && $v{image}) {
        $v{run_file} = FROM_to_name($v{image}) . "/default-run.sh";
        -e $v{run_file} or die("no $app/run.sh and no $v{run_file}\n");
    } elsif (-e "$app/run.env") {
        -e $v{run_file} or die("no $app/run.sh and no Dockerfile and no image= in $app/run.env\n");
    }

    $v{runOnce_file} =
        -e "$app/runOnce.sh" ? "$app/runOnce.sh" :
        -e "$app/runOnce.env" ? ".helpers/_runOnce.sh" : undef;

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

sub build {
    my ($app, $isRunOnce) = @_;
    my $image = $isRunOnce ? "up1-once-$app" : "up1-$app";
    my $opts = $isRunOnce ? "-f $app/runOnce.dockerfile" : '';
    my $cmd = "docker build $opts -t $image $app/";
    log_($cmd);
    open(my $F, "$cmd |");
    my @may_show = "${YELLOW}Building image $image${NC}\n";
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
    $status
}

my %built;
sub may_build_many {
    my ($appsv, $isRunOnce) = @_;
    my %todo = map { $_->{name} => $_ } grep {
        -e ($isRunOnce ? "$_->{name}/runOnce.dockerfile" : "$_->{name}/Dockerfile")
    } @$appsv;

    my %previously_built = map { /^up1-(.*):latest/ ? ($1 => 1) : () } `docker image ls --format '{{.Repository}}:{{.Tag}}'`;

    my $rec; $rec = sub {
        my ($app, $child) = @_;

        my $appv = delete $todo{$app};
        if ($built{$app}) {
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
        $built{$app} = build($app, $isRunOnce);
        $built{$app}
    };

    while (%todo) {
        my $app = (sort keys %todo)[0];
        $rec->($app);
    }

}

my %pulled;
sub may_pull {
    my ($image) = @_;
    if ($image && $image !~ /^up1-/ && !$pulled{$image}) {
        # ce n'est pas une image locale, on demande la dernière version (pour les rolling tags)
        print STDERR "${YELLOW}docker pull $image${NC}\n";
        sys("docker", "pull", $image);
        print "\n";
        $pulled{$image} = 1;
    }
}

sub pull {
    my ($appv) = @_;
    may_pull($appv->{image});
    may_pull($appv->{image_runOnce}) if !$opts{only_run};
    may_pull($appv->{FROM});
    may_pull($appv->{FROM_runOnce}) if !$opts{only_run};
}

sub run {
    my ($appv) = @_;
    log_(qq(Running "VERBOSE=1 ./$appv->{run_file} $appv->{name}" :));
    sys("./$appv->{run_file}", $appv->{name});
}

sub run_once {
    my ($appv) = @_;
    $appv->{runOnce_file} or die("ERROR: no runOnce.sh nor runOnce.env\n");
    log_(qq(Running "container_name=$appv->{name} $appv->{runOnce_file} @ARGV"));
    $ENV{container_name} = $appv->{name};
    $ENV{QUIET} = $opts{quiet};
    sys($appv->{runOnce_file}, @ARGV);

}

sub may_run_many {
    my ($appsv) = @_;
    my @l = grep { $_->{run_file} } @$appsv;
    if ($opts{if_old}) {
        my %old_containers = map { $_ => 1 } old_containers();
        @l = grep { $old_containers{$_->{name}} } @l;
        @l or print "${YELLOW}Aucun conteneurs à re-créer${NC}\n";
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
    my $old = $old_containers->{$app} ? " ${YELLOW}(containeur needs rerun)$NC" : '';
    my $image_state = $old_or_missing_images->{$app} ? " ${YELLOW}(image is $old_or_missing_images->{$app})$NC" : '';
    if ($state eq 'running') {
        if (!$opts{quiet} || $old || $image_state) {
            printf "%s $GREEN%s$NC%s\n", $app, $state, $old . $image_state;
        }
    } else {
        printf "%s $RED%s$NC\n", $app, uc($state);
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
            my ($appv) = grep { $_->{name} eq $app } @$appsv or warn("${RED}unknown image $name${NC}\n"), next;
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
                $h->{parent} .= " $YELLOW(old)$NC";
            } else {
                push @{$_->{children}}, $h->{name} foreach $parent;
                $h->{parent} = $parent->{name};
                $h->{parent} =~ s/([:-]prev\d*)?$/$YELLOW . ($1||'') . $NC/e;
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
    printf $format, "NAME$YELLOW$NC", 'CREATED' . $RED.$NC, 'SIZE', "PARENT $YELLOW$NC", 'CONTAINERS', 'ENFANTS';
    foreach my $h (sort { $a->{name} cmp $b->{name} } values %images) {
        $h->{name} =~ s/([:-]prev\d*)?$/$YELLOW . ($1||'') . $NC/e;
        printf $format, 
            $h->{name}, 
            $h->{missing} ? "${RED}missing${NC}" : $h->{CreatedSince} . $RED.$NC, 
            $h->{size} || '', 
            $h->{parent} || " $YELLOW$NC", 
            join(', ', @{$h->{containers_once} || []}) . ' ' .
              ($h->{containers} ? "$GREEN" . join(', ', @{$h->{containers}}) . "$NC" :
                $h->{children} || $h->{missing} || $h->{containers_once} || $h->{name} =~ /^up1-once-/ ? '' : "${YELLOW}unused${NC}"), 
            "$GRAY" . join(', ', @{$h->{children} || []}) . "$NC";
    }
}

sub usage {
    die(<<"EOS");
usage: 
    $0 upgrade [--verbose] [<app> ...]
    $0 pull [--only-run] { --all | <app> ... }
    $0 build [--only-run] [--verbose] { --all | <app> ... }
    $0 { run | build-run } [--if-old] [--verbose] [--logsf] { --all | <app> ... }
    $0 { runOnce | build-runOnce | runOnce-run } [--quiet] <app> [--cd <dir|subdir>] <args...>
    $0 purge
    $0 images
    $0 ps [--quiet] [--check-image-old] [<app> ... ]
    $0 rights [--quiet] { --all | <app> ... }
    $0 stop-rm [--quiet] { --all | <app> ... }
EOS
}

if ($> != 0 ) {
  die("Re-lancer avec sudo\n");
}

my ($want_upgrade, $want_purge, $want_build, $want_pull, $want_run, $want_build_runOnce, $want_runOnce, $want_ps, $want_images, $want_stop_rm);
my %actions = (
    'build' => sub { $want_build = 1 },
    'purge' => sub { $want_purge = 1 },
    'images' => sub { $want_images = 1 },
    'pull' => sub { $want_pull = $want_ps = $opts{check_image_old} = 1 },
    'run' => sub { $want_run = 1 },
    'build-run' => sub { $want_build = $want_run = 1 },
    'upgrade' => sub { $want_build = $want_build_runOnce = $want_pull = $want_run = $want_upgrade = $opts{if_old} = $opts{only_run} = 1 },
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
    if (my ($opt) = grep { $ARGV[0] eq $_ } "--only-run", "--logsf", "--quiet", "--verbose", "--if-old", "--check-image-old") {
        shift;
        $opt =~ s/^--//;
        $opt =~ s/-/_/g;
        $opts{$opt} = 1;
    } else {
        last;
    }
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
        # tell run.sh to be verbose
        $opts{verbose} = $ENV{VERBOSE} = 1;
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
        $opts{quiet} or print "$_ ignoré (supprimer le fichier $_/IGNORE pour réactiver)\n";
    }
    !$ignore
} @apps;

my @appsv = map { compute_app_vars($_) } @apps;

if ($want_purge) {
    $opts{verbose} = 1;
    purge([@appsv]);
}
if ($want_pull) {
    pull($_) foreach @appsv;
}
if ($want_build) {
    may_build_many([@appsv], '') ;
    print STDERR "${YELLOW}Aucune image modifiée${NC}\n\n" if !grep { $built{$_} ne 'from_cache' } keys %built;
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

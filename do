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

sub may_get_image {
    my ($env_file) = @_;
    -e $env_file && `.helpers/check-and-prepare-run_env-file-vars --only-image $env_file` =~ /^image='(\S+)'/ && $1
}

sub old_containers {
    map { /(\S+) sha256:/ ? $1 : () } `docker ps --no-trunc --format '{{.Names}} {{.Image}}'`
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
    } elsif (-e "$app/run.env") {
        die "no $app/run.sh\n";
    }

    $v{runOnce_file} =
        -e "$app/runOnce.sh" ? "$app/runOnce.sh" :
        -e "$app/runOnce.env" ? ".helpers/_runOnce.sh" : undef;

    $v{image} = may_get_image("$app/run.env");
    $v{image_runOnce} = may_get_image("$app/runOnce.env");

    \%v
}


my @user_files = qw(Dockerfile runeOnce.dockerfile run.env runOnce.env);

sub apply_rights {
    my ($app) = @_;
    sys('chmod', 700, '.git');
    sys('chmod', 750, $app);
    if (-e "$app/IGNORE") {
        # l'utilisateur n'existe sûrement pas => pas de chgrp du répertoire, mais le chmod 750 est suffisant
    } elsif (-e "$app/default-run.sh") {
    } elsif (grep { -e "$app/$_" } @user_files) {
        my $user = $app =~ /(.*)--/ && $1 || $app;
        sys("chgrp", $user, $app);
        -e $_ and sys("chown", "-R", $user, $_) foreach map { "$app/$_" } @user_files;
        my $sudoer_file = "/etc/sudoers.d/dockers-$app";
        if (! -e $sudoer_file) {
            write_file($sudoer_file, <<EOS);
$user ALL=(root) NOPASSWD: /opt/dockers/do build $app
$user ALL=(root) NOPASSWD: /opt/dockers/do build-run $app
$user ALL=(root) NOPASSWD: /opt/dockers/do run $app
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce $app
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce $app *
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce-run $app
$user ALL=(root) NOPASSWD: /opt/dockers/do runOnce-run $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker ps --filter name=$app
$user ALL=(root) NOPASSWD: /usr/bin/docker exec -it $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker exec $app *
$user ALL=(root) NOPASSWD: /usr/bin/docker logs $app
$user ALL=(root) NOPASSWD: /usr/bin/docker logs $app *
EOS
        }
    }

    may_symlink('/opt/dockers/.helpers/various/git-hook-apply-rights', '.git/hooks/post-rewrite',
        sub { "Installing $_[0] in $_[1]\n" });
    may_symlink('/opt/dockers/.helpers/various/bash_autocomplete', '/etc/bash_completion.d/opt_dockers_do',
        sub { "Installing $_[0] in $_[1]\n" });
}

sub build {
    my ($app, $isRunOnce) = @_;
    my $image = $isRunOnce ? "up1-once-$app" : "up1-$app";
    print "Building image $image\n";
    my $opts = $isRunOnce ? "-f $app/runOnce.dockerfile" : '';
    my $cmd = "docker build $opts -t $image $app/";
    log_($cmd);
    open(my $F, "$cmd |");
    my $out;
    while (<$F>) {
        print if /^Step/; # afficher une information de progression, mais pas tout
        $out .= $_;
    }
    close($F) or do {
        print $out;
        exit 1;
    }
}

my %built;
sub may_build_many {
    my ($appsv, $isRunOnce) = @_;
    my %todo = map { $_->{name} => $_ } grep {
        -e ($isRunOnce ? "$_->{name}/runOnce.dockerfile" : "$_->{name}/Dockerfile")
    } @$appsv;

    my %previously_built = map { /^up1-(.*):latest/ ? ($1 => 1) : () } `docker images --format '{{.Repository}}:{{.Tag}}'`;

    if ($opts{if_old}) {
        my %old_or_missing_images = old_or_missing_images($appsv, $isRunOnce);
        # ces images sont à jour, pas besoin de les reconstruire
        %built = map { $_ => 1 } grep { !$old_or_missing_images{$_} } keys %todo;
    }

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
        build($app, $isRunOnce);
        $built{$app} = 1;
        'modified'
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
        print "docker pull $image\n";
        sys("docker", "pull", $image);
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

    # supprimer les anciens images/containers non utilisés
    sys("docker system prune -f >/dev/null");
}

sub run_once {
    my ($appv) = @_;
    $appv->{runOnce_file} or die("ERROR: no runOnce.sh nor runOnce.env\n");
    log_(qq(Running "container_name=$appv->{name} $appv->{runOnce_file} @ARGV"));
    $ENV{container_name} = $appv->{name};
    sys($appv->{runOnce_file}, @ARGV);

}

sub may_run_many {
    my ($appsv) = @_;
    my @l = grep { $_->{run_file} } @$appsv;
    if ($opts{if_old}) {
        my %old_containers = map { $_ => 1 } old_containers();
        @l = grep { $old_containers{$_->{name}} } @l;
    }
    run($_) foreach @l;
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
    my %states = map { split } `docker ps -a --format "{{.Names}} {{.State}}"`;
    my %old_containers = map { $_ => 1 } old_containers();
    my %old_or_missing_images = $opts{check_image_old} ? old_or_missing_images($appsv) : ();
    ps($_->{name}, \%states, \%old_containers, \%old_or_missing_images) foreach grep { $_->{run_file} } @$appsv;
}

sub usage {
    die(<<"EOS");
usage: 
    $0 upgrade [--verbose] [<app> ...]
    $0 pull [--only-run] { --all | <app> ... }
    $0 build [--only-run] [--if-old] [--verbose] { --all | <app> ... }
    $0 { run | build-run } [--if-old] [--verbose] [--logsf] { --all | <app> ... }
    $0 { runOnce | build-runOnce | runOnce-run } <app> [--cd <dir|subdir>] <args...>
    $0 ps [--quiet] [--check-image-old] [<app> ... ]
    $0 rights [--quiet] { --all | <app> ... }
EOS
}

if ($> != 0 ) {
  die("Re-lancer avec sudo\n");
}

my ($want_upgrade, $want_build, $want_pull, $want_run, $want_build_runOnce, $want_runOnce, $want_ps);
my %actions = (
    'build' => sub { $want_build = 1 },
    'pull' => sub { $want_pull = $want_ps = $opts{check_image_old} = 1 },
    'run' => sub { $want_run = 1 },
    'build-run' => sub { $want_build = $want_run = 1 },
    'upgrade' => sub { $want_build = $want_build_runOnce = $want_pull = $want_run = $want_upgrade = $opts{if_old} = $opts{only_run} = 1 },
    'runOnce' => sub { $want_runOnce = 1 },
    'build-runOnce' => sub { $want_build_runOnce = $want_runOnce = 1 },
    'runOnce-run' => sub { $want_runOnce = $want_run = 1 },
    'rights' => sub { },
    'ps' => sub { $want_ps=1 },
);
my $action = shift;
my $set_opts = $actions{$action || ''} or usage();
$set_opts->();

chdir '/opt/dockers' or die;

while (1) {
    @ARGV or last;
    if (my ($opt) = grep { $ARGV[0] eq $_ } "--only-run", "--logsf", "--quiet", "--if-old", "--check-image-old") {
        shift;
        $opt =~ s/^--//;
        $opt =~ s/-/_/g;
        $opts{$opt} = 1;
    } else {
        last;
    }
}

my @apps;
if (@ARGV ? $ARGV[0] eq "--all" : $want_ps || $want_upgrade) {
    @apps = glob("*/");
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
    my $ignore = -e "$_/IGNORE";
    if ($ignore) {
        $opts{quiet} or print "$_ ignoré (supprimer le fichier $_/IGNORE pour réactiver)\n";
    }
    !$ignore
} @apps;

my @appsv = map { compute_app_vars($_) } @apps;

if ($want_pull) {
    pull($_) foreach @appsv;
}
if ($want_build) {
    may_build_many([@appsv], '') ;
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
if ($opts{logsf}) {
    exec('docker', 'logs', '-f', $apps[0]);
}

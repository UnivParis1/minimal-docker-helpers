#!/usr/bin/perl -l

sub get_apps {
    chdir "/opt/dockers";
    grep { -d $_ && -r $_ && ! -e "$_/IGNORE" } glob('*')
}

sub handle_runOnce {
    my ($index, @params) = @_;
    if ($index == 1) {
        return get_apps()
    } elsif ($index == 2) {
        return ("--cd", "<program>", "bash");
    } elsif ($index == 3 && $params[2] eq "--cd") {
        return ("<dir|subdir>", "_");
    } elsif ($index == 4 && $params[2] eq "--cd") {
        return ("<program>", "bash");
    }
}

sub all_cmds {
    my %cmd = (
        upgrade => '--verbose APPS',
        pull => '--only-run __ALL_OR_APPS',
        build => '--only-run --verbose __ALL_OR_APPS',
        run => '--if-old --verbose --logsf __ALL_OR_APPS',
        runOnce => 'RUN_ONCE',
        ps => '--quiet --check-image-old APPS',
        rights => '--quiet __ALL_OR_APPS',
        'stop-rm' => '--quiet __ALL_OR_APPS',
    );
    $cmd{'build-run'} = $cmd{run};
    $cmd{'build-runOnce'} = $cmd{runOnce};
    $cmd{'runOnce-run'} = $cmd{runOnce};
    return \%cmd;
}

sub do_ {
  my ($index, $_do, @params) = @ARGV;
  $index -= 1;

  my $cmds = all_cmds();
  if ($index == 0) {
    print foreach keys %$cmds;
  } else {
    my %present = map { $_ => 1 } @params;  
    my $prev_param = $index > 1 ? $params[$index -1] : '';
    my $allow_opts = !$prev_param || $prev_param =~ /^--/ && $prev_param ne '--all';
    my $has_app = $prev_param && $prev_param !~ /^--/;
    
    print foreach grep { 
        !$present{$_}
    } map {
        $_ eq 'APPS' ? get_apps() :
        $_ eq '__ALL_OR_APPS' ? ($present{"--all"} ? () : (($has_app ? () : '--all'), get_apps())) :
        $_ eq 'RUN_ONCE' ? handle_runOnce($index, @params) :
        $_
    } grep {
        ($allow_opts || !/^--/)
    } split(" ", $cmds->{$params[0]});
  }
}

sub sudo_do {
  my ($index, $_sudo, $_do, @params) = @ARGV;
  $index -= 2;

  # cf le /etc/sudoers.d/dockers-xxx généré dans le programme "do"
  if ($index == 0) {
    print "upgrade build run build-run runOnce";
  } else {
    my $cmd = $params[0];
    if ($cmd =~ /runOnce/) {
        print foreach handle_runOnce($index, @params);
    } else {
        print foreach get_apps()
    }
  }
}

if ($ARGV[1] eq 'sudo') {
    sudo_do();
} else {
    do_();
}

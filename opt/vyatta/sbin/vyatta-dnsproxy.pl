#!/usr/bin/perl

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Getopt::Long;

use strict;
use warnings;

my $dnsproxy_bin = '/usr/bin/dnsproxy';
my $dnsproxy_pid = '/var/run/dnsproxy.pid';
my $dnsproxy_args = '/var/run/dnsproxy.args';
my $dnsproxy_log = '/var/log/dnsproxy.log';

my %upstream_modes = map { $_ => 1} ('load_balance', 'parallel', 'fastest_addr');

sub dnsproxy_running {
    return -e $dnsproxy_pid;
}

sub dnsproxy_stop {
    if (dnsproxy_running()) {
        system("start-stop-daemon --stop --retry 5 --pidfile $dnsproxy_pid >&/dev/null");
    }
    system("pkill -TERM -f '^$dnsproxy_bin' >&/dev/null");
    unlink($dnsproxy_pid);
}

sub dnsproxy_start {
    my (@args) = @_;
    system('start-stop-daemon', '--start', '--background', '--make-pidfile', '--pidfile', $dnsproxy_pid, '--exec', $dnsproxy_bin, '--', @args);
}

sub dnsproxy_get_values {
    my $outside_cli = shift;
    my $config = new Vyatta::Config;

    $config->setLevel("service dnsproxy");

    my (@listen_addresses, $cache, $cache_size, $port, @options, @upstreams, $upstream_mode, $system);

    if ($outside_cli == 1) {
        @listen_addresses   = $config->returnOrigValues("listen-on");
        $cache              = $config->existsOrig("cache");
        $cache_size         = $config->returnOrigValue("cache-size");
        $port               = $config->returnOrigValue("port");
        @options            = $config->returnOrigValues("options");
        @upstreams          = $config->returnOrigValues("upstream");
        $upstream_mode      = $config->returnOrigValue("upstream-mode");
        $system             = $config->existsOrig("system");
    } else {
        @listen_addresses   = $config->returnValues("listen-on");
        $cache              = $config->exists("cache");
        $cache_size         = $config->returnValue("cache-size");
        $port               = $config->returnValue("port");
        @options            = $config->returnValues("options");
        @upstreams          = $config->returnValues("upstream");
        $upstream_mode      = $config->returnValue("upstream-mode");
        $system             = $config->exists("system");
    }

    if ($system && @upstreams != 0) {
        print "Warning: 'system' is defined, ignoring 'upstream'\n";
        @upstreams = ();
    }

    if ($system) {
        my $sys_config = new Vyatta::Config;
        $sys_config->setLevel("system");
        my @system_nameservers;
        if ($outside_cli == 1) {
            @system_nameservers = $sys_config->returnOrigValues("name-server");
        } else {
            @system_nameservers = $sys_config->returnValues("name-server");
        }

        if (@system_nameservers > 0) {
            @upstreams = @system_nameservers;
        } else {
            print "Warning: no name-servers set under 'system name-server'\n";
        }
    }

    if (@upstreams == 0) {
        die "Error: no upstream configured\n";
    }

    if (defined($cache_size) && !$cache) {
        print "Warning: 'cache-size' has no effect without 'cache'\n";
    }

    if (defined($upstream_mode) && !$upstream_modes{$upstream_mode}) {
        die "Error: invalid upstream-mode '$upstream_mode' (allowed: load_balance, parallel, fastest_addr)\n";
    }

    my @args;
    foreach my $address (@listen_addresses) {
        push @args, "--listen=$address";
    }
    push @args, "--port=$port"                 if defined $port;
    push @args, "--upstream=$_"                foreach @upstreams;
    push @args, "--upstream-mode=$upstream_mode" if defined $upstream_mode;
    push @args, "--cache"                      if $cache;
    push @args, "--cache-size=$cache_size"     if defined $cache_size && $cache;
    push @args, "--output=$dnsproxy_log";
    push @args, "$_"                           foreach @options;

    return @args;
}

sub dnsproxy_write_args {
    my ($args_ref) = @_;

    open(my $fh, '>', $dnsproxy_args) || die "Couldn't open $dnsproxy_args - $!";
    print $fh "$_\n" foreach @$args_ref;
    close($fh);
}

# main

my ($update_dnsproxy, $stop_dnsproxy, $outside_cli);

GetOptions("update-dnsproxy!" => \$update_dnsproxy,
           "stop-dnsproxy!"   => \$stop_dnsproxy,
           "outside-cli!"     => \$outside_cli);

my $called_from_outside_cli = 0;
$called_from_outside_cli = 1 if defined $outside_cli;

if (defined $update_dnsproxy) {
    my @args = dnsproxy_get_values($called_from_outside_cli);
    dnsproxy_write_args(\@args);
    dnsproxy_stop();
    dnsproxy_start(@args);
}

if (defined $stop_dnsproxy) {
    dnsproxy_stop();
}

exit 0;

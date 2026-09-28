#!/usr/bin/perl
#
# vyatta-dnsproxy.pl - glue between the EdgeOS CLI and the dnsproxy daemon.
#
# Reads the "service dnsproxy" configuration, translates it into dnsproxy
# command line arguments and manages the daemon lifecycle.
#
# Exit codes:
#   0 - success (also used when there is nothing to do)
#   1 - failure; a non-zero exit code makes the enclosing "commit" fail and
#       the message is shown to the user, which is the only reliable way to
#       report a broken DNS setup.
#
# Invocation modes:
#   --update-dnsproxy                 called by the commit hook; reads the
#                                     *candidate* (working) configuration
#   --update-dnsproxy --outside-cli   called from outside the configuration
#                                     session (ppp/ip-up.d, dhclient-script,
#                                     package postinst); reads the *active*
#                                     configuration
#   --stop-dnsproxy                   stop the daemon

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Getopt::Long;

use strict;
use warnings;

my $dnsproxy_bin = '/usr/bin/dnsproxy';
my $dnsproxy_pid = '/var/run/dnsproxy.pid';
my $dnsproxy_args = '/var/run/dnsproxy.args';
my $dnsproxy_log = '/var/log/dnsproxy.log';

# EdgeOS' own DNS forwarder (dnsmasq) always listens on port 53 - even when it
# only serves DHCP - so it cannot coexist with dnsproxy on the same port.
my $DNS_CONFLICT_PORT = 53;

my %upstream_modes = map { $_ => 1 } ('load_balance', 'parallel', 'fastest_addr');

# ---------------------------------------------------------------------------
# Cache sizing
#
# dnsproxy's --cache-size is expressed in BYTES: the value lands in
# golibs/cache Config.MaxSize, which bounds the total size of all stored keys
# and values.  EdgeOS' "service dns forwarding cache-size" is expressed in
# ENTRIES.  To stay migration friendly the CLI keeps the entry semantics and
# the value is converted here.
#
# $CACHE_BYTES_PER_ENTRY is a deliberately conservative estimate that covers
# the question (name + type), the compressed answer and the per-entry
# bookkeeping.  Because it is slightly larger than a typical record, the cache
# usually ends up holding somewhat more entries than requested.  The byte
# budget is what is actually enforced, so memory usage stays bounded
# regardless of the estimate.
my $CACHE_BYTES_PER_ENTRY = 256;

# golibs/cache defaults MaxElementSize to MaxSize, so an undersized MaxSize
# silently stops larger responses from ever being cached.  Never go below
# dnsproxy's own default of 64 KiB.
my $CACHE_MIN_BYTES = 64 * 1024;

# Mirrors "default: 10000" in the cache-size node.def.  The EdgeOS API normally
# returns template defaults from returnValue(), but the reference
# implementation guards against it not doing so, so do the same: enabling
# 'cache' without setting 'cache-size' must still yield the documented 10000
# entry budget rather than silently falling back to dnsproxy's 64 KiB.
# Keep this in sync with the template.
my $CACHE_ENTRIES_DEFAULT = 10000;

# ---------------------------------------------------------------------------
# helpers

# fatal() aborts with exit code 1 after reporting the problem on stderr.  It
# dies rather than calling exit() so that unit tests can catch it with eval.
# (Not named fail(), which several test frameworks already export.)
sub fatal {
    my ($msg) = @_;
    die "Error: $msg\n";
}

# warn_msg() reports on stdout so the text shows up in the commit output.
sub warn_msg {
    my ($msg) = @_;
    print "Warning: $msg\n";
}

sub _alive {
    my ($pid) = @_;
    return -d "/proc/$pid";
}

sub _read_pid {
    return undef unless -e $dnsproxy_pid;
    open(my $fh, '<', $dnsproxy_pid) or return undef;
    my $pid = <$fh>;
    close($fh);
    return undef unless defined $pid;
    chomp $pid;
    return ($pid =~ /^\d+$/) ? $pid : undef;
}

# _dnsproxy_pids() finds *all* running dnsproxy processes by command line, not
# just the one recorded in the pid file.  This is what guarantees that we never
# end up with two listeners competing for the same port.
sub _dnsproxy_pids {
    my @pids = `pgrep -f '^$dnsproxy_bin' 2>/dev/null`;
    chomp @pids;
    return grep { /^\d+$/ } @pids;
}

sub _dnsmasq_pids {
    my @out;
    foreach my $chunk (`pidof dnsmasq 2>/dev/null`) {
        chomp $chunk;
        push @out, grep { /^\d+$/ } split(/\s+/, $chunk);
    }
    return @out;
}

# _wait_gone() polls /proc until none of the given pids is alive any more.
# Returns 1 when they are all gone, 0 on timeout.
sub _wait_gone {
    my ($pids, $seconds) = @_;
    for (1 .. $seconds) {
        return 1 unless grep { _alive($_) } @$pids;
        sleep 1;
    }
    return (grep { _alive($_) } @$pids) ? 0 : 1;
}

# ---------------------------------------------------------------------------
# process lifecycle

sub dnsproxy_running {
    my $pid = _read_pid();
    return ($pid && _alive($pid)) ? 1 : 0;
}

# dnsproxy_stop() stops the daemon and, importantly, waits until it is really
# gone.  Starting the replacement while the old process still holds the
# listening socket would make the new one exit immediately.
sub dnsproxy_stop {
    if (-e $dnsproxy_pid) {
        system("start-stop-daemon --stop --retry TERM/30/KILL/5 " .
               "--pidfile $dnsproxy_pid >/dev/null 2>&1");
    }

    my @pids = _dnsproxy_pids();
    if (@pids) {
        system("pkill -TERM -f '^$dnsproxy_bin' >/dev/null 2>&1");
        unless (_wait_gone(\@pids, 15)) {
            warn_msg("dnsproxy did not stop within 15s, sending SIGKILL");
            system("pkill -KILL -f '^$dnsproxy_bin' >/dev/null 2>&1");
            _wait_gone(\@pids, 5);
        }
    }

    my @left = _dnsproxy_pids();
    if (@left) {
        print STDERR "Error: dnsproxy is still running (pids: @left)\n";
        return 0;
    }

    # Only drop the pid file once we know nothing is left behind, otherwise a
    # later start would lose track of the running instance.
    unlink($dnsproxy_pid);
    return 1;
}

sub dnsproxy_start {
    my (@args) = @_;

    my @already = _dnsproxy_pids();
    if (@already) {
        print STDERR "Error: refusing to start, dnsproxy is already running " .
                     "(pids: @already)\n";
        return 0;
    }

    my $rc = system('start-stop-daemon', '--start', '--background',
                    '--make-pidfile', '--pidfile', $dnsproxy_pid,
                    '--exec', $dnsproxy_bin, '--', @args);
    if ($rc != 0) {
        my $code = $rc >> 8;
        print STDERR "Error: failed to start dnsproxy (exit=$code)\n";
        return 0;
    }

    # Give the process a moment to bind its sockets, then make sure it did not
    # die on startup (missing binary, port already in use, bad option, ...).
    sleep 1;
    unless (dnsproxy_running()) {
        print STDERR "Error: dnsproxy exited right after start.  A common " .
                     "cause is that port $DNS_CONFLICT_PORT is already in use.\n";
        return 0;
    }
    return 1;
}

# ---------------------------------------------------------------------------
# dnsmasq mutual exclusion

# EdgeOS runs dnsmasq for two independent reasons: "service dns forwarding"
# (DNS) and "service dhcp-server use-dnsmasq enable" (DHCP).  In both cases
# dnsmasq listens on port 53, so dnsproxy cannot share that port with it.
sub _dnsmasq_needed_for_dhcp {
    my $cfg = new Vyatta::Config;
    return 0 unless $cfg->exists('service dhcp-server');

    my $use_dnsmasq = $cfg->returnValue('service dhcp-server use-dnsmasq');
    return 0 unless (defined $use_dnsmasq && $use_dnsmasq eq 'enable');

    my $disabled = $cfg->returnValue('service dhcp-server disabled');
    return 0 if (defined $disabled && $disabled eq 'true');

    return 1;
}

# check_dnsmasq_conflict() returns 1 when it is safe to start dnsproxy.
# The check is port aware: running dnsproxy on a port other than 53 alongside
# dnsmasq is legitimate and must not be blocked.
sub check_dnsmasq_conflict {
    my ($port) = @_;

    my @pids = _dnsmasq_pids();
    my $cfg  = new Vyatta::Config;
    my $fwd  = $cfg->exists('service dns forwarding')
            || $cfg->existsOrig('service dns forwarding');

    return 1 unless (@pids || $fwd);

    if (scalar(@pids) > 1) {
        warn_msg("more than one dnsmasq process is running (@pids); EdgeOS " .
                 "expects exactly one.");
    }

    my $effective_port = (defined $port && $port =~ /^\d+$/) ? $port
                                                             : $DNS_CONFLICT_PORT;
    if ($effective_port != $DNS_CONFLICT_PORT) {
        warn_msg("dnsmasq is running but dnsproxy listens on port " .
                 "$effective_port instead of $DNS_CONFLICT_PORT; continuing.");
        return 1;
    }

    my $msg = "dnsmasq is running and holds port $DNS_CONFLICT_PORT, which " .
              "conflicts with 'service dnsproxy'.\n" .
              "        Only one DNS forwarder can own port $DNS_CONFLICT_PORT.\n" .
              "        Remove the built-in forwarding configuration first:\n" .
              "            delete service dns forwarding\n" .
              "            commit\n";

    if (_dnsmasq_needed_for_dhcp()) {
        $msg .= "        NOTE: 'service dhcp-server use-dnsmasq' is enabled, so " .
                "dnsmasq is\n" .
                "        also serving DHCP and will keep port $DNS_CONFLICT_PORT " .
                "busy even after\n" .
                "        'service dns forwarding' is removed.  Either hand DHCP over\n" .
                "        to the ISC server:\n" .
                "            set service dhcp-server use-dnsmasq disable\n" .
                "            commit\n" .
                "        or let dnsproxy listen on a different port:\n" .
                "            set service dnsproxy port <port>\n";
    }

    print STDERR "Error: $msg";
    return 0;
}

# ---------------------------------------------------------------------------
# cache size conversion

# _cache_size_to_bytes() converts the configured number of entries into the
# byte budget expected by dnsproxy.  A configured value of 0 means "no cache"
# and is reported as 0 so that the caller can disable caching instead of
# silently falling back to dnsproxy's 64 KiB default.  Returns undef only for
# a malformed value, which the template syntax already rejects.
sub _cache_size_to_bytes {
    my ($entries) = @_;
    return undef unless defined $entries;
    return undef unless $entries =~ /^\d+$/;

    return 0 if $entries == 0;

    my $bytes = $entries * $CACHE_BYTES_PER_ENTRY;
    $bytes = $CACHE_MIN_BYTES if $bytes < $CACHE_MIN_BYTES;
    return $bytes;
}

# ---------------------------------------------------------------------------
# configuration translation

sub dnsproxy_get_values {
    my ($outside_cli) = @_;
    my $config = new Vyatta::Config;

    $config->setLevel("service dnsproxy");

    my (@listen_addresses, $cache, $cache_size, $cache_size_set, $port,
        @options, @upstreams, $upstream_mode, $system);

    if ($outside_cli == 1) {
        @listen_addresses   = $config->returnOrigValues("listen-on");
        $cache              = $config->existsOrig("cache");
        $cache_size         = $config->returnOrigValue("cache-size");
        $cache_size_set     = $config->existsOrig("cache-size");
        $port               = $config->returnOrigValue("port");
        @options            = $config->returnOrigValues("options");
        @upstreams          = $config->returnOrigValues("upstream");
        $upstream_mode      = $config->returnOrigValue("upstream-mode");
        $system             = $config->existsOrig("system");
    } else {
        @listen_addresses   = $config->returnValues("listen-on");
        $cache              = $config->exists("cache");
        $cache_size         = $config->returnValue("cache-size");
        $cache_size_set     = $config->exists("cache-size");
        $port               = $config->returnValue("port");
        @options            = $config->returnValues("options");
        @upstreams          = $config->returnValues("upstream");
        $upstream_mode      = $config->returnValue("upstream-mode");
        $system             = $config->exists("system");
    }

    if ($system && @upstreams != 0) {
        warn_msg("'system' is defined, ignoring 'upstream'");
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
            warn_msg("no name-servers set under 'system name-server'");
        }
    }

    if (@upstreams == 0) {
        # Called from the commit hook this is a genuine misconfiguration that
        # must be reported.  Called from an outside trigger (ppp link change,
        # package postinst) it usually just means the service is not
        # configured, so there is nothing to do and no reason to fail.
        return () if $outside_cli == 1;
        fatal("no upstream configured.  Set 'upstream <address>' or 'system'.");
    }

    if ($cache_size_set && !$cache) {
        warn_msg("'cache-size' has no effect without 'cache'");
    }

    if (defined $upstream_mode && !$upstream_modes{$upstream_mode}) {
        fatal("invalid upstream-mode '$upstream_mode' " .
             "(allowed: load_balance, parallel, fastest_addr)");
    }

    my $cache_bytes;
    if ($cache) {
        my $entries = defined $cache_size ? $cache_size : $CACHE_ENTRIES_DEFAULT;
        $cache_bytes = _cache_size_to_bytes($entries);
        if (defined $cache_bytes && $cache_bytes == 0) {
            warn_msg("'cache-size 0' disables caching; ignoring 'cache'");
            $cache = 0;
        }
    }

    my @args;

    # User supplied extra options come first so that they can never override
    # the arguments generated from the dedicated configuration nodes below.
    push @args, "$_"                             foreach @options;
    push @args, "--listen=$_"                    foreach @listen_addresses;
    push @args, "--port=$port"                   if defined $port;
    push @args, "--upstream=$_"                  foreach @upstreams;
    push @args, "--upstream-mode=$upstream_mode" if defined $upstream_mode;
    if ($cache) {
        push @args, "--cache";
        push @args, "--cache-size=$cache_bytes" if defined $cache_bytes;
    }
    push @args, "--output=$dnsproxy_log";

    return @args;
}

sub dnsproxy_write_args {
    my ($args_ref) = @_;

    my $tmp = "$dnsproxy_args.tmp";
    open(my $fh, '>', $tmp) or return 0;
    print $fh "$_\n" foreach @$args_ref;
    close($fh) or return 0;

    return rename($tmp, $dnsproxy_args) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# main

sub main {
    my ($update_dnsproxy, $stop_dnsproxy, $outside_cli);

    GetOptions('update-dnsproxy!' => \$update_dnsproxy,
               'stop-dnsproxy!'   => \$stop_dnsproxy,
               'outside-cli!'     => \$outside_cli)
        or fatal("invalid command line option.  Supported: " .
                 "--update-dnsproxy, --stop-dnsproxy, --outside-cli");

    # A negatable option is meaningless when it was not given at all, so test
    # the value rather than whether it is defined.
    my $outside = ($outside_cli ? 1 : 0);

    fatal("--update-dnsproxy and --stop-dnsproxy are mutually exclusive")
        if ($update_dnsproxy && $stop_dnsproxy);

    return 0 unless ($update_dnsproxy || $stop_dnsproxy);

    return (dnsproxy_stop() ? 0 : 1) if $stop_dnsproxy;

    my @args = dnsproxy_get_values($outside);
    return 0 unless @args;

    fatal("$dnsproxy_bin is missing or not executable") unless -x $dnsproxy_bin;

    # Both pre-flight checks run *before* the old instance is stopped, so a
    # rejected configuration never leaves the device without a resolver.
    my ($port) = map { /^--port=(.*)$/ ? $1 : () } @args;
    return 1 unless check_dnsmasq_conflict($port);

    unless (dnsproxy_write_args(\@args)) {
        print STDERR "Error: cannot write $dnsproxy_args: $!\n";
        return 1;
    }

    return 1 unless dnsproxy_stop();
    return 1 unless dnsproxy_start(@args);

    return 0;
}

# Run only when invoked as a program; a test harness may load this file to
# exercise the helper subroutines.
unless (caller) {
    my $rc = 0;
    eval { $rc = main(); 1 };
    if ($@) {
        print STDERR $@;
        exit 1;
    }
    exit($rc);
}

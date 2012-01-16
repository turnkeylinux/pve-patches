package PVE::APLInfo;

use strict;
use IO::File;
use PVE::SafeSyslog;
use PVE::I18N;
use LWP::UserAgent;
use PVE::Config;
use POSIX qw(strftime);

my @channels = (
    {'name' => 'proxmox',
     'index' => 'http://download.proxmox.com/appliances/aplinfo.dat.gz',
     'indexsig' => 'http://download.proxmox.com/appliances/aplinfo.dat.asc',
     'keyid' => '5CAC72FE',
     'keyserver' => '',
     'keyfile' => '/usr/share/doc/pve-manager/support@proxmox.com.pubkey'},

    {'name' => 'turnkeylinux',
     'index' => 'http://releases.turnkeylinux.org/pve/aplinfo.dat.gz',
     'indexsig' => 'http://releases.turnkeylinux.org/pve/aplinfo.dat.asc',
     'keyid' => 'A16EB94D',
     'keyserver' => 'hkp://keyserver.ubuntu.com',
     'keyfile' => ''},
);

my $logfile = "/var/log/pveam.log";

sub logmsg {
    my ($logfd, $msg) = @_;
    print "debug: $msg\n";

    chomp $msg;

    my $tstr = strftime ("%b %d %H:%M:%S", localtime);

    foreach my $line (split (/\n/, $msg)) {
	print $logfd "$tstr $line\n";
    }
}

sub url_get {
    my ($ua, $url, $file, $logfh) = @_;

    my $req = HTTP::Request->new(GET => $url);

    logmsg ($logfh, "url_get: $url");
    my $res = $ua->request($req, $file);

    if ($res->is_success) {
	logmsg ($logfh, "url_get: " . $res->status_line);
	return 0;
    }

    logmsg ($logfh, "url_get: " . $res->status_line);

    return 1;
}

sub update {
    my ($proxy) = @_;

    my $size;
    if (($size = (-s $logfile) || 0) > (1024*50)) {
        system ("mv $logfile $logfile.0");
    }
    my $logfd = IO::File->new (">>$logfile");
    logmsg ($logfd, "channel updates: initiated");

    my $tmpapl = "/tmp/pveam.apl.tmp.$$";
    system ("rm -f $tmpapl");

    eval {
    for (my $i=0; $i < scalar (@channels); $i++) {

        my $name = $channels[$i]{'name'};
        logmsg ($logfd, "$name: starting...");

        my $tmp = "/tmp/pveam.$name.tmp.$$";
        my $tmpgz = "$tmp.gz";
        my $sigfn = "$tmp.asc";

        # setup user-agent, proxy. supports ftp and http.
        local $ENV{FTP_PASSIVE} = 1;
        my $ua = LWP::UserAgent->new;
        $ua->agent("PVE/1.0");
        if ($proxy) { $ua->proxy(['http'], $proxy);
        } else { $ua->env_proxy; }

        # pull index and gpg sig
        logmsg ($logfd, "$name: getting index signature");
        if (url_get ($ua, $channels[$i]{'indexsig'}, $sigfn, $logfd) != 0) {
            die "$name: update failed - no signature\n";
        }

        logmsg ($logfd, "$name: getting index");
        if (url_get ($ua, $channels[$i]{'index'}, $tmpgz, $logfd) != 0) {
            die "$name: update failed - no data\n";
        }
     
        if (system ("zcat -f $tmpgz >$tmp 2>/dev/null") != 0) {
            die "$name: update failed: unable to unpack '$tmpgz'\n";
        }

        # import gpg keys if needed
        my $keyid = $channels[$i]{'keyid'};
        my $keyfile = $channels[$i]{'keyfile'};
        my $keyserver = $channels[$i]{'keyserver'};

        if (system ("/usr/bin/gpg --logger-fd=1 --list-keys $keyid 2>&1 >/dev/null") != 0) {
            if ( $keyfile ) {
                logmsg ($logfd, "$name: importing $keyid from $keyfile");
                system ("/usr/bin/gpg --batch --no-tty --status-fd=1 -q " .
                        "--logger-fd=1 --import $keyfile >>$logfile");
            }
            if ( $keyserver ) {
                logmsg ($logfd, "$name: importing $keyid from $keyserver");
                system ("/usr/bin/gpg --keyserver $keyserver --recv-keys " .
                        "--logger-fd=1 0x$keyid >>$logfile");
            }
        }

        # verify index integrity
        logmsg ($logfd, "$name: verifying index integrity");
        if (system ("/usr/bin/gpg --logger-fd=1 --verify $sigfn $tmp 2>&1 >>$logfile") != 0) {
            die "$name: unable to verify signature\n";
        }

        # validate index syntax
        logmsg ($logfd, "$name: validating index syntax");
        eval { 
            my $fh = IO::File->new ("<$tmp") ||
            die "unable to open file '$tmp' - $!\n";
            PVE::Config::read_aplinfo ($tmp, $fh, 1);
            close ($fh);
        };
        die "update failed, invalid syntax: $@" if $@;

        # append channel index to main tmp appliance list
        system ("cat $tmp >> $tmpapl");
        logmsg ($logfd, "$name: update complete");
    }

    logmsg ($logfd, "channel updates: finalizing");
	if (system ("mv $tmpapl /var/lib/pve-manager/apl-available 2>/dev/null") != 0) { 
	    die "update failed: unable to store data\n";
	}

    logmsg ($logfd, "channel updates: complete");
    };
    my $err = $@;
    if ($err) {
        logmsg ($logfd, $err);
        close ($logfd);
        return 0;
    }
    close ($logfd);
    return 1;
}

sub load_data {
    my $filename = "/var/lib/pve-manager/apl-available";

    if (! -f $filename) {
	system ("cp /usr/share/doc/pve-manager/aplinfo.dat /var/lib/pve-manager/apl-available");
    }

    return PVE::Config::read_file ('aplinfo');
}

sub display_name {
    my ($template) = @_;

    my $templates = load_data ();

    return $template if !$templates;

    my $d =  $templates->{'all'}->{$template};

    $template =~ s/\.tar\.gz$//;
    $template =~ s/_i386$//;

    return $template if !$d;

    return "$d->{package}_$d->{version}";
}

sub pkginfo {
    my ($template) = @_;

    my $templates = load_data ();

    return undef if !$templates;

    my $d =  $templates->{'all'}->{$template};

    return $d;
}

sub webnews {
    my ($lang) = @_;

    my $templates = load_data ();

    my $html = '';

    $html .= __("<b>Welcome</b> to the Proxmox Virtual Environment!");
    $html .= "<br><br>";
    $html .= __("For more information please visit our homepage at");
    $html .= " <a href='http://www.proxmox.com' target='_blank'>www.proxmox.com</a>.";

    return $html if !$templates;

    # my $d = $templates->{'all'}->{"pve-web-news-$lang"} ||
    my $d = $templates->{all}->{'pve-web-news'};

    return $html if !$d;

    return $d->{description};
}

1;


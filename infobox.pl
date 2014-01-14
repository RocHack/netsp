#!/usr/bin/perl

use strict;
use warnings;
use Sys::Hostname;
use Socket;
use POSIX;

# after this amount of time, re-check
my $TIME = 60;
# after this amount of time, command fails
my $TIMEOUT = 5;

my @now = localtime time;
my $year = $now[5] + 1900;
my %mons = ( Jan => '01',
             Feb => '02',
             Mar => '03',
             Apr => '04',
             May => '05',
             Jun => '06',
             Jul => '07',
             Aug => '08',
             Sep => '09',
             Oct => '10',
             Nov => '11',
             Dec => '12' );

my $fhost = hostname;
$fhost =~ m#([^.]+)\..*#;
my $host = $1;

# possible alrmdq options...
# first element: only check status, do not store usage
# second element: drive to query with `df`
# third element: user-friendly disk name
my $alrmdq = { l => [ 'l', 0, '/localdisk', 'localdisk', 0 ],
                   u => [ 'u', 1, '/home/hoover/*', 'hoover', 1 ],
                   w => [ 'w', 1, '/home/anon/httpd', 'anon', 0 ],
                   m => [ 'm', 1, '/var/spool/mail', 'dorito', 0 ] };

# handle command line args...
# -x host:
# where x is a mode and host is the desired host (defaults to -C $host, the current host as a computer)
my $alrmdq_option = 'luwm';
my $mode = 'computer';
if ($#ARGV == 1 || $#ARGV == 0) {
    if ($ARGV[0] eq '-u') { # nfs_drive user drive (hoover)
        $alrmdq_option = 'u';
        $mode = 'nfs_drive';
    } elsif ($ARGV[0] eq '-w') { # nfs_drive web drive (anon)
        $alrmdq_option = 'w';
        $mode = 'nfs_drive';
    } elsif ($ARGV[0] eq '-m') { # nfs_drive mail drive (dorito)
        $alrmdq_option = 'm';
        $mode = 'nfs_drive';
    } elsif ($ARGV[0] eq '-p') { # printer (west or inner)
        $alrmdq_option = '';
        $mode = 'printer';
    } elsif ($ARGV[0] eq '-C') { # computer (default: local host, cycle1, cycle2, cycle3, ...)
        $alrmdq_option = 'luwm';
        $mode = 'computer';
    } elsif ($ARGV[0] eq '-l') { # computer_limited (niagara1, niagara2, utility1)
        $alrmdq_option = 'uw';
        $mode = 'computer_limited';
    } elsif ($ARGV[0] eq '-c') { # camera (camera1, camera2, camera3), UNUSED
        $alrmdq_option = '';
        $mode = 'camera';
        print STDERR "[$host] This mode is unused. Exiting.\n";
        exit(0);
    }
    $host = $ARGV[1] if $#ARGV == 1;
}

my $disk_qv = [];
foreach my $chr (split //, $alrmdq_option) {
    push @$disk_qv, $alrmdq->{$chr};
}

$0 = "infobox.pl url=csug:/u/www/u/nbook/csugnet/infobox.php host=$host mode=$mode";

print "[$host] infobox daemon init: $0\n";

# file setup
my $file = "data/$host";

unless (-e $file) {
    open my $fh, '>', $file
        or do { print STDERR "[$host] Cannot create $file: $!\n"; exit 1; };
    close $fh;
    chmod 0644, $file; # make sure webserver can read this file
    print "[$host] File created.\n";
}

my $name_dict = { };

my $users;

sub m2n {
    return $mons{shift @_};
}

sub kb2h {
    my $k = shift @_;
    my $m = $k / 1024;
    my $g = $m / 1024;
    my $t = $g / 1024;
    if ($k < 1024) {
        return $k.' KB';
    } elsif ($m < 1024) {
        return sprintf('%.1f', $m).'MB';
    } elsif ($g < 1024) {
        return sprintf('%.1f', $g).'GB';
    } else {
        return sprintf('%.1f', $t).'TB';
    }
}

sub perc {
    my $u = shift @_;
    my $t = shift @_;
    return sprintf('%.1f', ($u / $t) * 100).'%';
}

# returns the disk statistics for a partition with a timeout
sub alrmdq {
    my $arr = shift;
    my $totarg = '--total ';
    my $src = 'total';
    my $dst = '';
    my $result = '';
    if ($mode eq 'computer_limited' or not $arr->[4]) {
        $totarg = '';
        $src = '';
        $dst = $arr->[2];
    }

    # hack to make all of /home/hoover/* show up
    if ($arr->[3] eq 'hoover' and $mode eq 'nfs_drive') {
        alrmcmd('ls /u/');
    }

    # actually get disk stats for disk $arr[2]
    my $df = alrmcmd("df -ak $totarg$arr->[2]");
    # if valid line matching 
    if ($df =~ m#$src\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+$dst#) {
        if ($arr->[1] and not $mode eq 'nfs_drive') {
            $result = "$arr->[3],1,$arr->[2];";
        } else {
            my @parts = ( int $1, int $2, int $3, int $4 );
            my $total = kb2h($parts[0]);
            my $used = kb2h($parts[1]);
            my $avail = kb2h($parts[2]);
            my $percent = perc($parts[1], $parts[0]);
            $result = "$arr->[3],1,$arr->[2],$total,$used,$avail,$percent;";
        }
    } else {
        $result = "$arr->[3],0;";
    }
    $arr->[5] = $result;
    return $result;
}

# executes a shell command with a timeout
sub alrmcmd {
    my $cmd = shift;
    my $result = '';
    my $pid = open PROC, "$cmd |" or die $!;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n"; };
        alarm $TIMEOUT;
        $result .= $_ while <PROC>;
        while (<PROC>) {$result .= $_;}
        close PROC;
        alarm 0;
    };
    if ($@) {
        kill 9 => $pid;
        close PROC;
        unless ($@ eq "timeout\n") {
            plog("[$host] Operation failed ($cmd): $!\n");
            #kill TERM => $pid unless (kill 0 => $pid); # forceful close PROC
        } else {
            plog("[$host] Operation timed out ($TIMEOUT seconds): $cmd\n");
        }
        return '';
    } else {
        return $result;
    }
}

# gets printer status (via pjstatus system) with a timeout
sub alrmpjs {
    my $online = 0;
    my $status = [];

    my $proto = getprotobyname("tcp");
    socket SOCK, PF_INET, SOCK_STREAM, $proto
        or do { plog("[$host] Socket: $!\n"); return ( 0, [] ); };

    eval {
        local $SIG{ALRM} = sub { die "timeout\n"; };
        alarm $TIMEOUT;
        my $port = 9100;
        my $iaddr = inet_aton($host) or die "[$host] Unable to resolve: $!";
        my $paddr = sockaddr_in($port, $iaddr);
        connect SOCK, $paddr
            or do { plog("[$host] Connect: $!\n"); return ( 0, [] ); };
        SOCK->autoflush(1);
        my $request = "\e%-12345X\@PJL \r\n\@PJL INFO STATUS \r\n\e%-12345X";
        #print `echo -n "$request" | hexdump -C`;
        print SOCK $request;
        my $code = 0;
        my $idx = 1;
        while (my $line = <SOCK>) {
            #print $line;
            #print `echo -n "$line" | hexdump -C`;
            if ($line =~ /CODE(\d+|)=(\d+)\r\n/) {
                $code = int $2;
                $idx = $1;
                $idx = 1 if length($idx) == 0;
            } elsif ($line =~ /DISPLAY(\d+|)="(.*)"\r\n/) {
                $idx = $1;
                $idx = 1 if length($idx) == 0;
                push @$status, "$code $2";
            } elsif ($line eq "ONLINE=TRUE\r\n") {
                $online = 1;
                last;
            } elsif ($line eq "ONLINE=FALSE\r\n") {
                $online = 0;
                last;
            }
        }
        close SOCK;
        alarm 0;
    };
    if ($@) {
        close SOCK;
        my $op = "PJSTATUS $host";
        unless ($@ eq "timeout\n") {
            plog("[$host] Operation failed ($op): $!\n");
        } else {
            plog("[$host] Operation timed out ($TIMEOUT seconds): $op\n");
        }
        return ( 0, [] );
    } else {
        return ( $online, $status );
    }
    return ( $online, $status );
}

# scrapes the webpage for the printer for ink and paper info with a timeout
sub alrmpjsw {
    my $inklvl = {};
    my $pprlvl = [];
    
    my $web_content = alrmcmd("curl -s http://$host/hp/device/this.LCDispatcher");
    
    if (length($web_content) > 0) {
        if ($web_content =~ /(\S+) Cartridge&nbsp;&nbsp;(\d+)%/) {
            $inklvl->{$1} = $2;
        }
        while ($web_content =~ /Tray (\d+)[^&]+&nbsp;&nbsp;(\w+)/g) {
            push @$pprlvl, $2;
        }
    }

    return ( $inklvl, $pprlvl );
}

# compare for sort on pjstatus output, where lines starting with 'STATUS' are placed first
sub cmp_pjkeys {
    my $a_cmp = $a;
    my $b_cmp = $b;
    $a_cmp = 'A'.substr($a, 6) if substr($a, 0, 6) eq 'STATUS';
    $b_cmp = 'A'.substr($b, 6) if substr($b, 0, 6) eq 'STATUS';
    return $a_cmp cmp $b_cmp;
}


sub daemonize {
    my $pid = fork;
    if ($pid < 0) {
        print STDERR "[$host] Could not separate from shell because fork() failed: $!\n";
        return 0;
    }
    $pid and exit;
    setsid;
    close(STDIN);
    close(STDOUT);
    close(STDERR);
    return 1;
}

sub plog {
    my $out = shift;
    open my $fh, '>>', "data/$host.log" or return;
    print $fh $out;
    close $fh;
}

if (!daemonize()) {
    plog("[$host] infobox daemon init: $0\n");
}

my $osn = '', my $ost = '', my $osv = 0;

while (1) {
    if ($mode eq 'computer' or $mode eq 'computer_limited') {
        if ($osn eq '') {
            $ost = alrmcmd('uname -a');
            if ($ost =~ /\.fc(\d+)/) {
                $osn = 'fedora';
                $osv = $1;
                $ost = alrmcmd('cat /etc/fedora-release');
            } elsif ($ost =~ /\.el(\d+)/) {
                $osn = 'rhel';
                $osv = $1;
                $ost = alrmcmd('cat /etc/redhat-release');
            } elsif ($ost =~ /^SunOS/) {
                $osn = 'sunos';
                $osv = 0;
                $ost = alrmcmd('cat /etc/release | head -n 1');
                $ost =~ s/^\s+|\s+$//g;
            } elsif ($ost =~ /^Linux/) {
                $osn = 'gnu';
                $osv = 0;
                $ost = 'GNU/Linux (unknown)';
            } else {
                $osn = 'unknown';
                $osv = 0;
                $ost = 'Unknown OS';
            }
        }

        my $uptime = alrmcmd('uptime');
        $uptime =~ m#.*up (?:(\d+) day\(?s?\)?, )?\s?(?:(\d+):)?(\d+)(?: min)?, \s?(\d+) users?.*#;
        my @up = ( int $1, int $2, int $3 );

        plog("[$host] Up for $up[0] days, $up[1] hours, and $up[2] minutes.\n");
        my $changes = 0;

        my $new_users = [];
        my $who = alrmcmd('who');
        while ($who =~ m#(\S+)\s+(pts/\d+|tty\d+|\:\d+)\s+(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}|\S{3}\s+\d+\s+\d+:\d{2})(\s\(\S+\)|).*#g) {
            my $arr = [ $1, $2, $3, $4, '' ];
            # get date
            # niagara style:
            if ($arr->[2] =~ m#(\S{3})\s+(\d+)\s+(\d+):(\d{2})#) {
                $arr->[2] = "$year-".m2n($1)."-$2 $3:$4:00";
            }
            # get host
            if ($arr->[3] =~ m#\s\((\S+)\)#) {
                $arr->[3] = $1;
            }
            if (length($arr->[3]) == 0) {
                $arr->[3] = '*';
            }
            # get realname
            my $netid = $arr->[0];
            if (exists $name_dict->{$netid}) {
                $arr->[4] = $name_dict->{$netid};
            } else {
                my $finger = alrmcmd("finger -ms $arr->[0]");
                if ($finger =~ m#$arr->[0]\s+((?:\S+\s)*\S+)\s+#) {
                    $arr->[4] = $1;
                    $name_dict->{$netid} = $arr->[4];
                } else {
                    $arr->[4] = $arr->[0];
                }
                plog("[$host] Unknown user '$arr->[0]' = '$arr->[4]'\n");
            }
            push @$new_users, $arr;
        }

        my $disks = '';
        foreach my $disk (@$disk_qv) {
            if ($disk->[1]) {
                if ($#$disk < 5) {
                    plog("[$host] Querying $disk->[3] status ($disk->[2])\n");
                    $disks .= alrmdq($disk);
                } else {
                    $disks .= $disk->[5];
                }
            } else {
                plog("[$host] Querying $disk->[3] size and usage ($disk->[2])\n");
                $disks .= alrmdq($disk);
            }
        }
        
        my $user_count = $#{$users} + 1;
        
        #print "Size: $blocks\nUsed: $used\nAvail: $avail\nPercent: $percent\n";

        $changes++ if $#{$new_users} != $#{$users};
        $users = $new_users;

        if ($changes > 0) {
            plog("[$host] There are ".($#{$users}+1)." users on now.\n");
        }

        if (open my $fh, '>', $file) {
            print $fh "$up[0]:$up[1]:$up[2]:$disks:$osn:$osv:$ost\n";
            foreach my $user (@{$users}) {
                print $fh "$user->[0] $user->[1] $user->[2] $user->[3] $user->[4]\n";
            }

            close $fh;
            plog("[$host] Written $file.\n");
        } else {
            plog("[$host] Cannot open $file: $!\n");
        }
    } elsif ($mode eq 'nfs_drive') {
        plog("[$host] Requesting status/size for $#$disk_qv disks.\n");
        $osn = 'netdisk';
        $osv = 0;
        $ost = 'Networked Storage Device';
        my $disks = '';
        foreach my $disk (@$disk_qv) {
            $disks .= alrmdq($disk);
        }

        if (open my $fh, '>', $file) {
            print $fh "0:0:0:$disks:$osn:$osv:$ost\n";
            close $fh;
            plog("[$host] Written $file.\n");
        } else {
            plog("[$host] Cannot open $file: $!\n");
        }
    } elsif ($mode eq 'printer') {
        plog("[$host] Requesting status/ink/paper for printer.\n");
        $osn = 'hpp';
        $osv = 0;
        $ost = 'HP Printer';
        my %vars;
        ( my $online, my $status ) = alrmpjs($host);
        ( my $inklvl, my $pprlvl ) = alrmpjsw($host);
        my $i = 0;
        foreach my $s (@$status) {
            $i++;
            $vars{"STATUS_$i"} = $s;
        }
        foreach my $s (keys %$inklvl) {
            $vars{'INK_'.uc $s} = $inklvl->{$s}.'%';
        }
        $i = 0;
        foreach my $s (@$pprlvl) {
            $i++;
            $vars{'TRAY_'.$i} = $s;
        }

        if (open my $fh, '>', $file) {
            print $fh "0:0:0:$online:$osn:$osv:$ost\n";
            foreach my $key (sort cmp_pjkeys keys %vars) {
                print $fh "$key=$vars{$key}\n";
            }
            close $fh;
            plog("[$host] Written $file.\n");
        } else {
            plog("[$host] Cannot open $file: $!\n");
        }
    }
    
    sleep $TIME;
}



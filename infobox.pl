#!/usr/bin/perl
#
use strict;
use warnings;
use utf8;
use Sys::Hostname;
use Socket;
use POSIX;
use JSON;
use Encode;
use Time::Local;

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
my %disk_list = ( localdisk => '/localdisk' );
if ($#ARGV == 1 || $#ARGV == 0) {
    %disk_list = ();
    if ($ARGV[0] eq '-u') { # nfs_drive user drive (hoover)
        $alrmdq_option = 'u';
        $mode = 'nfs_drive';
        $disk_list{'hoover/u1'} = '/home/hoover/u1';
        $disk_list{'hoover/u2'} = '/home/hoover/u2';
        $disk_list{'hoover/u3'} = '/home/hoover/u3';
        $disk_list{'hoover/u4'} = '/home/hoover/u4';
        $disk_list{'hoover/u5'} = '/home/hoover/u5';
    } elsif ($ARGV[0] eq '-w') { # nfs_drive web drive (anon)
        $alrmdq_option = 'w';
        $mode = 'nfs_drive';
        $disk_list{'anon/http'} = '/home/anon/httpd';
        $disk_list{'anon/ftp'} = '/home/anon/ftp';
    } elsif ($ARGV[0] eq '-m') { # nfs_drive mail drive (dorito)
        $alrmdq_option = 'm';
        $mode = 'nfs_drive';
        $disk_list{'dorito'} = '/var/spool/mail';
    } elsif ($ARGV[0] eq '-p') { # printer (west or inner)
        $alrmdq_option = '';
        $mode = 'printer';
    } elsif ($ARGV[0] eq '-C') { # computer (default: local host, cycle1, cycle2, cycle3, ...)
        $alrmdq_option = 'luwm';
        $mode = 'computer';
        $disk_list{localdisk} = '/localdisk';
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

$0 = "infobox.pl host=$host mode=$mode see-url=http://csug.rochester.edu/u/nbook/csugnet.html";

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
my $userfolder_dict = { };

sub lock {
    my $fname = shift;
    open my $fh, '>', "$fname.lock"
        or do { plog("[$host] Cannot create $fname.lock: $!\n"); exit 1; };
    print $fh $host;
    close $fh;
    plog("[$host] Locked $fname.\n");
}

sub unlock {
    my $fname = shift;
    unlink "$fname.lock";
    plog("[$host] Unlocked $fname.\n");
}

sub lockWrite {
    local $/;
    my $fname = shift;
    my $name = shift;
    my $value = shift;
    while (-e "$fname.lock") {
        open my $fhl, '<', "$fname.lock" or last;
        my $otherhost = <$fhl> if defined($fhl);
        close $fhl;
        if ($host eq $otherhost) {
            # held by self or no .lock contents
            unlink "$fname.lock";
            last;
        }
        plog("[$host] Waiting for lock held by $otherhost\n");
        sleep 1;
    }
    lock($fname);
    open my $fh, '<', $fname
        or do { plog("[$host] Cannot open $fname for reading: $!\n"); unlock($fname); exit 1; };
    my $oldjson = decode_json <$fh>;
    close $fh;
    foreach my $host (@{$oldjson->{hosts}}) {
        if ($host->{name} eq $name) {
            $host = $value;
        }
    }
    my $data = encode_json $oldjson;
    open my $fhw, '>', $fname
        or do { plog("[$host] Cannot open $fname for writing: $!\n"); unlock($fname); exit 1; };
    print $fhw $data;
    close $fhw;
    unlock($fname);
}

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
        #print $cmd.'=>'.$result;
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

sub parseSession {
    my $tty = shift;
    my $host = shift;
    my $result = { type => 'unknown', fromParse => $host, numeric => -1 };
    if ($tty =~ m#pts/(\d+)#) {
        if (substr($host, 0, 1) eq ':') {
            $result->{type} = 'screen';
            $result->{numeric} = $1 + 0;
            if ($host =~ m#:([^:]+):S\.(\d+)#) {
                $result->{screenNumeric} = $2 + 0;
                $result->{fromParse} = parseSession($1, '*');
            }
        } else {
            $result->{type} = 'ssh';
            $result->{numeric} = $1 + 0;
        }
    } elsif ($tty =~ m#tty(\d+)#) {
        $result->{type} = 'tty';
        $result->{numeric} = $1 + 0;
    } elsif ($tty =~ m#:(\d+)#) {
        $result->{type} = 'login';
        $result->{numeric} = $1 + 0;
    } elsif ($tty =~ m#rdesktop#) {
        $result->{type} = 'remote';
        $result->{numeric} = 0;
        if ($host =~ m#:([^:]+)#) {
            my $fromParse = parseSession($1, '*');
            $result->{fromParse} = $fromParse;
        }
    }
    return $result;
}

# elements of the json output:
my $os;
my $cpu;
my $mem;
my $users;
my $disks;

# storing of elements that don't change while this script runs:
# OS, CPU, RAM
if ($mode eq 'computer' or $mode eq 'computer_limited') {
    # populate os
    my $ost = alrmcmd('uname -a');
    my $sunos = 0;
    if ($ost =~ /\.fc(\d+)/) {
        $os = { class => 'fedora', version => $1 + 0, releaseFile => '/etc/fedora-release' };
    } elsif ($ost =~ /\.el(\d+)/) {
        $os = { class => 'rhel', version => $1 + 0, releaseFile => '/etc/redhat-release' };
    } elsif ($ost =~ /^SunOS/) {
        $sunos = 1;
        $ost = alrmcmd('cat /etc/release | head -n 1');
        $ost =~ /Solaris (\d+)/;
        $os = { class => 'sunos', version => $1 + 0, releaseFile => '/etc/release' };
    } else {
        $os = { class => 'unknown', version => 0 };
    }
    if (exists $os->{releaseFile}) {
        my $rel = alrmcmd("cat $os->{releaseFile} | head -n 1");
        $rel =~ s/^\s+|\s+$//g;
        $os->{release} = $rel;
        $os->{displayIcon} = $os->{class}.'.png';
    }

    # populate cpu
    if ($sunos) {
        # set cpu.model, cpu.cores, cpu.threads, and cpu.speed
        my $cput = alrmcmd('/usr/sbin/prtdiag');
        my @lines = split /\n/, $cput;
        foreach my $line (@lines) {
            if ($line =~ /^(\d+)\s+(\d+)\sMHz\s+(\S+)\s+on-line\s*$/) {
                (my $n, my $mhz, my $name) = ($1, $2, $3);
                $cpu->{model} = $name;
                $cpu->{modelClean} = $name;
                $cpu->{modelClean} =~ s/SUNW,//;
                $cpu->{threads} = $n + 1;
                $cpu->{cores} = ($n + 1) / 4;
                $cpu->{speed} = $mhz + 0;
            }
        }
        
        # set mem.total
        my $memt = alrmcmd('/usr/sbin/prtconf | head -n 2');
        if ($memt =~ /Memory size: (\d+) Megabytes/) {
            $mem = { total => $1 * 1024 };
        }
    } else {
        # set cpu.model, cpu.cores, cpu.threads, and cpu.speed
        my $cput = alrmcmd('cat /proc/cpuinfo');
        if ($cput =~ /model name\s+:\s+(.*)\s+stepping/) {
            $cpu->{model} = $1;
            $cpu->{modelClean} = $cpu->{model};
            $cpu->{modelClean} =~ s/\bCPU\b|\s@\s|\b[\d.]+\s?[TGM]Hz\b//g;
            $cpu->{modelClean} =~ s/^\s+(.*?)\s+$/$1/;
        }
        if ($cput =~ /siblings\s+:\s+(\d+)/) {
            $cpu->{threads} = $1 + 0;
            $cpu->{threads} = 1 if ($cpu->{threads} == 0);
        } else {
            $cpu->{threads} = 1;
        }
        if ($cput =~ /cpu cores\s+:\s+(\d+)/) {
            $cpu->{cores} = $1 + 0;
            $cpu->{cores} = 1 if ($cpu->{cores} == 0);
        } else {
            $cpu->{cores} = 1;
        }
        if ($cput =~ /cpu MHz\s+:\s+([\d.]+)/) {
            $cpu->{speed} = $1 + 0;
        }

        # set mem.total
        my $memt = alrmcmd('cat /proc/meminfo | head -n 1');
        if ($memt =~ /MemTotal:\s+(\d+) kB/) {
            $mem = { total => $1 + 0 };
        }
    }
}

if (%disk_list) {
    # set disks[] of {name,size,used,percent}
    my @disk_list_v = values %disk_list;
    my $diskt = alrmcmd("df --output=target,size,used @disk_list_v");
    while ($diskt =~ m#(\S+)\s+(\d+)\s+(\d+)#g) {
        (my $path, my $total, my $used) = ($1, $2 + 0, $3 + 0);
        my $name = $path;
        while ((my $key, my $value) = each %disk_list) {
            if ($value eq $path) {
                $name = $key;
                last;
            }
        }
        push @{$disks}, {
            name => $name,
            path => $path,
            total => $total,
            used => $used
        };
    }
}

while (1) {
    # modification of data/<host> files, kept around for the previous page to continue to function
    my $up_time_s = -1;
    if ($mode eq 'computer' or $mode eq 'computer_limited') {
        my $uptime = alrmcmd('uptime');
        $uptime =~ m#.*up (?:(\d+) day\(?s?\)?, )?\s?(?:(\d+):)?(\d+)(?: min)?, \s?(\d+) users?.*#;
        my @up = ( int $1, int $2, int $3 );
        $up_time_s = $up[0] * 86400 + $up[1] * 3600 + $up[2] * 60;

        plog("[$host] Up for $up[0] days, $up[1] hours, and $up[2] minutes.\n");
        my $changes = 0;

        my $new_users = [];
        my $who = alrmcmd('who');
        while ($who =~ m#(\S+)\s+(\S+)\s+(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}|\S{3}\s+\d+\s+\d+:\d{2})(\s+\(\S+\)|).*#g) {
            my $arr = { netid => $1, tty => $2, loginTimeString => $3, host => $4 };
            # get date
            # niagara style:
            if ($arr->{loginTimeString} =~ m#(\S{3})\s+(\d+)\s+(\d+):(\d{2})#) {
                $arr->{loginTimeString} = "$year-".m2n($1)."-$2 $3:$4:00";
            }
            # get timestamp
            my @login_time = $arr->{loginTimeString} =~
                m/(\d{4})-(\d{2})-(\d{2})\s(\d{2}):(\d{2})/;
            $login_time[1]--;
            my $login_time_s = timelocal 0,@login_time[4,3,2,1,0];
            $arr->{loginTime} = $login_time_s;
            # get host
            if ($arr->{host} =~ m#\s\((\S+)\)#) {
                $arr->{host} = $1;
            }
            if (length($arr->{host}) == 0) {
                $arr->{host} = '*';
            }
            # parse host
            $arr->{session} = parseSession($arr->{tty}, $arr->{host});
            # check for user folder
            if (exists $userfolder_dict->{netid}) {
                $arr->{folderExists} = $userfolder_dict->{netid};
            } else {
                my $uf = 0;
                if (-d "/u/www/u/$arr->{netid}") {
                    $uf = 1;
                }
                $userfolder_dict->{netid} = $uf;
                $arr->{folderExists} = $uf;
            }
            # get real name
            my $netid = $arr->{netid};
            if (exists $name_dict->{$netid}) {
                $arr->{name} = $name_dict->{$netid};
            } else {
                my $finger = alrmcmd("finger -ms $arr->{netid}");
                if ($finger =~ m#$arr->{netid}\s+((?:\S+\s)*\S+)\s+#) {
                    $name_dict->{$netid} = $arr->{name} = $1;
                } else {
                    $arr->{name} = $arr->{netid};
                }
                plog("[$host] Unknown user '$arr->{netid}' = '$arr->{name}'\n");
            }
            push @$new_users, $arr;
        }

        my $disks_str = '';
        foreach my $disk (@$disk_qv) {
            if ($disk->[1]) {
                if ($#$disk < 5) {
                    plog("[$host] Querying $disk->[3] status ($disk->[2])\n");
                    $disks_str .= alrmdq($disk);
                } else {
                    $disks_str .= $disk->[5];
                }
            } else {
                plog("[$host] Querying $disk->[3] size and usage ($disk->[2])\n");
                $disks_str .= alrmdq($disk);
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
            print $fh "$up[0]:$up[1]:$up[2]:$disks_str:$os->{class}:$os->{version}:$os->{release}\n";
            foreach my $user (@{$users}) {
                print $fh "$user->{netid} $user->{tty} $user->{loginTimeString} ".
                          "$user->{host} $user->{name}\n";
            }
            close $fh;
            plog("[$host] Written $file.\n");
        } else {
            plog("[$host] Cannot open $file: $!\n");
        }
    } elsif ($mode eq 'nfs_drive') {
        plog("[$host] Requesting status/size for $#$disk_qv disks.\n");
        my $disks = '';
        foreach my $disk (@$disk_qv) {
            $disks .= alrmdq($disk);
        }

        if (open my $fh, '>', $file) {
            print $fh "0:0:0:netdisk:0:Network Drive\n";
            close $fh;
            plog("[$host] Written $file.\n");
        } else {
            plog("[$host] Cannot open $file: $!\n");
        }
    } elsif ($mode eq 'printer') {
        plog("[$host] Requesting status/ink/paper for printer.\n");
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
            print $fh "0:0:0:$online:hpp:0:HP Printer\n";
            foreach my $key (sort cmp_pjkeys keys %vars) {
                print $fh "$key=$vars{$key}\n";
            }
            close $fh;
            plog("[$host] Written $file.\n");
        } else {
            plog("[$host] Cannot open $file: $!\n");
        }
    }

    # prepare to write to data.json
    my $current_time = time;
    my $last_change_s = $current_time - $up_time_s;
    my $object = {};
    $object->{name} = $host;
    $object->{state} = 'Up';
    $object->{color} = 'green';
    $object->{lastCheck} = $current_time;
    if ($up_time_s >= 0) {
        $object->{lastChange} = $last_change_s;
        $object->{upTime} = $up_time_s;
    }
    $object->{os} = $os if defined($os);
    $object->{cpu} = $cpu if defined($cpu);
    $object->{mem} = $mem if defined($mem);
    $object->{users} = $users if defined($users);
    $object->{disks} = $disks if defined($disks);
    lockWrite('data.json', $host, $object);
    
    sleep $TIME;
}



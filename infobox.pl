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
# after this amount of time, a computer is set to down ($IS_MASTER)
my $TIMEISDOWN = 300;
# after this amount of time, attempt to re-start another computer's script if it's down ($IS_MASTER)
my $TIMEREINIT = 3600;
# after this amount of time, command fails
my $TIMEOUT = 5;

## MAIN CODE START
my $fhost = hostname; $fhost =~ m#([^.]+)\..*#;
my $host = $1;

# elements of the data.json output:
my $name_cache = { };
my $userFolder_cache = { };

my $os;
my $cpu;
my $mem;
my $users;
my $disks;
my $inks;
my $trays;

# handle command line args...
# --master/--slave --debug
my $IS_MASTER = 1;
$::IS_DEBUG = 0;
if ($#ARGV >= 0) {
    foreach my $arg (@ARGV) {
        if ($arg eq '--master') {
            $IS_MASTER = 1;
        } elsif ($arg eq '--slave') {
            $IS_MASTER = 0;
        } elsif ($arg eq '--debug') {
            $::IS_DEBUG = 1;
        }
    }
}


# static-setup.json
my $hostObj;
my $static_setup;
if (open my $ssfh, '<', 'static-setup.json') {
    local $/;
    my $staticObj = decode_json <$ssfh>;
    close $ssfh;
    $static_setup = $staticObj;
} else {
    plog("[$host] Cannot open static-setup.json for reading: $!\n");
    exit 1;
}

if ($IS_MASTER) {
    $0 = '--master';
    $host .= '--master';
} else {
    $0 = "--slave";
}
$0 = "infobox.pl $0 --see-url=https://csug.rochester.edu/u/nbook/csugnet.html";

plog("[$host] $0\n", 1);

if (!daemonize()) {
    exit;
}

if ($IS_MASTER) {
    # MASTER runs ONCE, and handles all COMPUTER SCRIPTS, and checks PRINTERS, CAMERAS, NFS DRIVESa
    # INIT_INFOBOX.SH:
    if (defined $static_setup and exists $static_setup->{hosts}) {
        foreach my $ss_host (@{$static_setup->{hosts}}) {
            if ($ss_host->{type} eq 'computer' and not $ss_host->{perminantDown}) {
                remote_initialize($ss_host->{name});
            }
        }
    }

    while (1) {
        my $current_time = time;
        my $last_check_time;
        my $last_change_time;
        my $object;
        my $up_time_s;
        my $last_check_diff;
        my $last_change_diff;
        # check all 
        if (defined $static_setup and exists $static_setup->{hosts}) {
            plog("[$host] Requesting status for printers, cameras, and servers.\n");
            foreach my $ss_host (@{$static_setup->{hosts}}) {
                $object = readDataLock($ss_host->{name});
                $last_check_time = $object->{lastCheck};
                if (defined($object->{lastChange})) {
                    $last_change_time = abs $object->{lastChange};
                    $last_change_diff = $current_time - $last_change_time;
                } else {
                    $last_change_time = -1;
                    $last_change_diff = 0;
                }
                if (defined($object->{lastCheck})) {
                    $last_check_time = abs $object->{lastCheck};
                    $last_check_diff = $current_time - $last_check_time;
                } else {
                    $last_check_time = -1;
                    $last_check_diff = -1;
                }
                $up_time_s = $last_change_diff;
                #print "host $ss_host->{name} up $up_time_s s, check $last_check_diff s ago, change $last_change_diff s ago\n";
                if ($ss_host->{type} eq 'computer') {
                    if ($object->{state} eq 'Up' and $last_check_diff > $TIMEISDOWN) {
                        $last_change_time = $last_check_time + $TIME;
                        $up_time_s = -($last_check_diff - $TIME);
                        $object->{lastChange} = $last_change_time;
                    } else {
                        unlock('data.json');
                        next;
                    }
                } else {
                    $up_time_s = 1;
                }

                if ($ss_host->{type} eq 'printer' and not $ss_host->{perminantDown}) {
                    # check each printer
                    ( my $psuccess, my $pstate, my $pmodel, my $inks, my $trays ) =
                        alrmpjsw($ss_host->{name});
                    if ($psuccess) {
                        $object->{prText} = $pstate;
                        $object->{prModel} = $pmodel;
                        $object->{inks} = $inks;
                        $object->{trays} = $trays;
                    } else {
                        # down
                        $up_time_s = -$up_time_s;
                        if ($object->{state} eq 'Up') {
                            $object->{lastChange} = $current_time;
                        }
                    }
                }

                if (defined $ss_host->{nfsDisks} and @{$ss_host->{nfsDisks}}) {
                    # set disks[] of {name,size,used,percent}
                    my $disks = [];
                    my @disk_list = @{$ss_host->{nfsDisks}};
                    my $diskt = alrmcmd("df --output=target,size,used @disk_list");
                    while ($diskt =~ m#(\S+)\s+(\d+)\s+(\d+)#g) {
                        (my $path, my $total, my $used) = ($1, $2 + 0, $3 + 0);
                        push @{$disks}, {
                            path => $path,
                            total => $total,
                            used => $used
                        };
                    }

                    $object->{disks} = $disks;
                }

                if ($up_time_s >= 0) {
                    $object->{state} = 'Up';
                    $object->{color} = 'green';
                } else {
                    $object->{state} = 'Down';
                    $object->{color} = 'red';
                }
                writeData($ss_host->{name}, $object);
            }
        }

        sleep $TIME;
    }
} else {
    # SLAVES check COMPUTERS
    if (defined $static_setup and exists $static_setup->{hosts}) {
        foreach my $ss_host (@{$static_setup->{hosts}}) {
            if (exists $ss_host->{name} and $ss_host->{name} eq $host) {
                $hostObj = $ss_host;
            }
        }
    }
    if (not defined $hostObj) {
        plog("[$host] Cannot find self data in static-setup.json or empty static-setup.json.\n");
        exit 1;
    }

    # storing of elements that don't change while this script runs:
    # OS, CPU, RAM
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

    if (defined $hostObj->{localDisks} and @{$hostObj->{localDisks}}) {
        # set disks[] of {name,size,used,percent}
        my @disk_list = @{$hostObj->{localDisks}};
        my $diskt = alrmcmd("df --output=target,size,used @disk_list");
        while ($diskt =~ m#(\S+)\s+(\d+)\s+(\d+)#g) {
            (my $path, my $total, my $used) = ($1, $2 + 0, $3 + 0);
            push @{$disks}, {
                path => $path,
                total => $total,
                used => $used
            };
        }
    }

    # primary loop
    while (1) {
        # modification of data/<host> files, kept around for the previous page to continue to function
        my $up_time_s = -1;

        my $uptime = alrmcmd('uptime');
        $uptime =~ m#.*up (?:(\d+) day\(?s?\)?, )?\s?(?:(\d+):)?(\d+)(?: min)?, \s?(\d+) users?.*#;
        my @up = ( int $1, int $2, int $3 );
        $up_time_s = $up[0] * 86400 + $up[1] * 3600 + $up[2] * 60;

        plog("[$host] Up for $up[0] days, $up[1] hours, and $up[2] minutes.\n");

        $users = [];
        my $who = alrmcmd('who');
        while ($who =~
m#(\S+)\s+(\S+)\s+(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}|\S{3}\s+\d+\s+\d+:\d{2})(\s+\(\S+\)|).*#g) {
            my $arr = { netid => $1, tty => $2, loginTimeString => $3, host => $4 };
            # get date
            # solaris style:
            if ($arr->{loginTimeString} =~ m#(\S{3})\s+(\d+)\s+(\d+):(\d{2})#) {
                $arr->{loginTimeString} = currY().'-'.m2n($1)."-$2 $3:$4:00";
            }
            # get timestamp
            my @login_time = $arr->{loginTimeString} =~
                m/(\d{4})-(\d{2})-(\d{2})\s(\d{2}):(\d{2})/;
            $login_time[1]--; # 0-based month value
            my $login_time_s = timelocal 0,@login_time[4,3,2,1,0];
            $arr->{loginTime} = $login_time_s;
            # get host
            if ($arr->{host} =~ m#\s\((\S+)\)#) {
                $arr->{host} = $1;
            }
            if (length($arr->{host}) == 0) {
                $arr->{host} = '*';
            }
            # check for user folder
            #if (exists $userFolder_cache->{netid}) {
            #    $arr->{folderExists} = $userFolder_cache->{netid};
            #} else {
                my $uf = 0;
                if (-d "/u/www/u/$arr->{netid}") {
                    $uf = 1;
                }
                #$userFolder_cache->{netid} = $uf;
                $arr->{folderExists} = $uf;
            #}
            # get real name
            my $netid = $arr->{netid};
            if (exists $name_cache->{$netid}) {
                $arr->{name} = $name_cache->{$netid};
            } else {
                my $finger = alrmcmd("finger -ms $arr->{netid}");
                if ($finger =~ m#$arr->{netid}\s+((?:\S+\s)*\S+)\s+#) {
                    $name_cache->{$netid} = $arr->{name} = $1;
                } else {
                    $arr->{name} = $arr->{netid};
                }
                plog("[$host] Unknown user '$arr->{netid}' = '$arr->{name}'\n");
            }
            push @$users, $arr;
        }

        # prepare to write to data.json
        my $object = {};
        $object->{os} = $os if defined($os);
        $object->{cpu} = $cpu if defined($cpu);
        $object->{mem} = $mem if defined($mem);
        $object->{users} = $users if defined($users);
        $object->{disks} = $disks if defined($disks);
        $object->{state} = 'Up';
        $object->{color} = 'green';
        my $current_time = time;
        my $last_change_s = $current_time - (abs $up_time_s);
        $object->{lastChange} = $last_change_s;
        $object->{lastCheck} = $current_time;
        writeData($host, $object);
        
        sleep $TIME;
    }
}


## SUBROUTINES
sub remote_initialize {
    return;
    my $inithost = shift;
    my $ssh = "ssh $inithost ".
    '"cd www/csugnet; PERL5LIB=/u/nbook/perl5/lib/perl5 ./infobox.pl --slave"';
    plog("[$host] $inithost initializing\n");
    my $result = alrmcmd($ssh);
}

# filesystem-based locking
# LOCK()
sub lock {
    my $fname = shift;
    open my $fh, '>', "$fname.lock"
        or do { plog("[$host] Cannot create $fname.lock: $!\n"); exit 1; };
    print $fh $host;
    close $fh;
    #plog("[$host] Locked $fname.\n");
}

# UNLOCK()
sub unlock {
    my $fname = shift;
    unlink "$fname.lock";
    #plog("[$host] Unlocked $fname.\n");
}

sub readDataLock {
    my $read_host = shift;

    my $fname = 'data.json';
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
    my $jsonObj;
    if (open my $fh, '<', $fname) {
        local $/;
        $jsonObj = decode_json <$fh>;
        close $fh;
    } else {
        plog("[$host] Cannot open $fname for reading: $!\n");
        unlock($fname);
        exit 1;
    }
    foreach my $h (@{$jsonObj->{hosts}}) {
        if ($h->{name} eq $read_host) {
            return $h;
        }
    }
    return {};
}

# write an object to a file as JSON using lock/unlock
sub writeData {
    my $write_host = shift;
    my $object = shift;

    my $fname = 'data.json';
    while (-e "$fname.lock") {
        if (open my $fhl, '<', "$fname.lock") {
            my $otherhost = <$fhl>;
            close $fhl;
            if ($host eq $otherhost) {
                # held by self or no .lock contents
                unlink "$fname.lock";
                last;
            }
            plog("[$host] Waiting for lock held by $otherhost\n");
            sleep 1;
        } else {
            last;
        }
    }
    lock($fname);
    my $jsonObj;
    if (open my $fh, '<', $fname) {
        local $/;
        $jsonObj = decode_json <$fh>;
        close $fh;
    } else {
        plog("[$host] Cannot open $fname for reading: $!\n");
        unlock($fname);
        exit 1;
    }
    $object->{name} = $write_host;
    foreach my $hostObj (@{$jsonObj->{hosts}}) {
        if ($hostObj->{name} eq $write_host) {
            $hostObj = $object;
        }
    }
    my $data = encode_json $jsonObj;
    open my $fhw, '>', $fname
        or do { plog("[$host] Cannot open $fname for writing: $!\n"); unlock($fname); exit 1; };
    print $fhw $data;
    close $fhw;
    unlock($fname);
}

# solaris date conversion
sub m2n {
    my %mons = ( Jan => '01', Feb => '02', Mar => '03', Apr => '04', May => '05', Jun => '06',
        Jul => '07', Aug => '08', Sep => '09', Oct => '10', Nov => '11', Dec => '12' );
    return $mons{shift @_};
}
sub currY {
    my @now = localtime time;
    return $now[5] + 1900;
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
    my $prhost = shift;
    my $success = 1;
    my $state = '';
    my $model = '';
    my $inklvl = [];
    my $pprlvl = [];
    
    my $web_content = alrmcmd("curl -sL http://$prhost/hp/device/this.LCDispatcher");
    
    if (length($web_content) > 0) {
        if ($web_content =~ /padding-bottom: \.7em;" >([^<]+)/) {
            $state = $1;
        } else {
            $success = 0;
        }
        if ($web_content =~ /hpBannerTextBig">\s*([^<]+)/) {
            $model = $1;
        } else {
            $success = 0;
        }
        if ($web_content =~ /(\S+) Cartridge&nbsp;&nbsp;(\d+)%/) {
            push @$inklvl, { color => $1, amount => $2 + 0 };
        } else {
            $success = 0;
        }
        while ($web_content =~ /Tray (\d+)[^&]+&nbsp;&nbsp;(\w+)/g) {
            push @$pprlvl, { index => $1 + 0, state => $2 };
        }
    } else {
        $success = 0;
    }

    return ( $success, $state, $model, $inklvl, $pprlvl );
}

# compare for sort on pjstatus output, where lines starting with 'STATUS' are placed first
sub cmp_pjkeys {
    my $a_cmp = $a;
    my $b_cmp = $b;
    $a_cmp = 'A'.substr($a, 6) if substr($a, 0, 6) eq 'STATUS';
    $b_cmp = 'A'.substr($b, 6) if substr($b, 0, 6) eq 'STATUS';
    return $a_cmp cmp $b_cmp;
}


# fork from the parent 
sub daemonize {
    return 1 if ($::IS_DEBUG);
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
    my $print_to_shell = shift;
    print $out if ($print_to_shell or $::IS_DEBUG);
    open my $fh, '>>', "data/$host.log" or return;
    print $fh $out;
    close $fh;
}


#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use Sys::Hostname;
use Time::Local;
use JSON;
use POSIX;

my $_TIME_S_MINUTE = 60;
my $_TIME_S_HOUR = 3600;
my $_TIME_S_DAY = 86400;

my $_TIME = $_TIME_S_MINUTE;
my $_TIME_IS_DOWN = $_TIME_S_MINUTE * 15;
my $_CMD_TIMEOUT = 5;

$::host = hostname;
$::host =~ m/^([^.]+)\./;
$::host = $1;

$::network_folder = '';
$::is_master = 1;
$::is_debug = 0;
$::is_forked = 0;
do {
    my $netf_thisarg = 0;
    my $m_set = 0;
    my $d_set = 0;
    foreach my $arg (@ARGV) {
        if ($netf_thisarg) {
            $::network_folder = $arg;
        } elsif ($arg eq '--net') {
            $netf_thisarg = 1;
        } elsif ($arg eq '--slave' and not $m_set) {
            $m_set = 1;
            $::is_master = 0;
        } elsif ($arg eq '--master' and not $m_set) {
            $m_set = 1;
            $::is_master = 1;
        } elsif ($arg eq '--debug' and not $d_set) {
            $d_set = 1;
            $::is_debug = 1;
        } elsif (substr($arg, 0, 1) eq '-') {
            foreach my $argc (split //, $arg) {
                if ($argc eq 's' and not $m_set) {
                    $m_set = 1;
                    $::is_master = 0;
                } elsif ($argc eq 'm' and not $m_set) {
                    $m_set = 1;
                    $::is_master = 1;
                } elsif ($argc eq 'd' and not $d_set) {
                    $d_set = 1;
                    $::is_debug = 1;
                }
            }
        }
    }
};

if (not $::network_folder eq 'csug' and not $::network_folder eq 'urcs') {
    pr_log("Network unknown or not defined. Must be 'csug' or 'urcs' for now. Aborting.\n");
    exit;
}

my $url = "https://csug.rochester.edu/ugc/netsp-$::network_folder.html";
$0 = "infobox.pl master=$::is_master debug=$::is_debug $url";

pr_log("$0\n");

if (!daemonize()) {
    exit;
}

my @actions = ( );
my $index = 0;
my $total = 0;
$::sta_data = read_json_file($::network_folder . '/static-setup.json');
if (validate_hash($::sta_data, { hosts => 'ARRAY'})) {
    foreach my $hostObj (@{$::sta_data->{hosts}}) {
        if (validate_hash($hostObj, { name => 'SCALAR', type => 'SCALAR' })) {
            $total++;
            my $perm_down = 0;
            $perm_down = 1 if exists $hostObj->{permanentDown} and
                $hostObj->{permanentDown};
            if (!$perm_down) {
                if ($::is_master) {
                    if (exists $hostObj->{nfsDisks}) {
                        push @actions, {
                            host => $hostObj->{name},
                            name => 'check_nfs_disks',
                            action => \&check_nfs_disks,
                            repeat => 15
                        };
                    }
                    if ($hostObj->{type} eq 'computer' and
                        not $hostObj->{name} eq $::host) {
                        push @actions, {
                            host => $hostObj->{name},
                            name => 'check_computer_timeout',
                            action => \&check_computer_timeout,
                            repeat => 1
                        };
                    } elsif ($hostObj->{type} eq 'printer') {
                        push @actions, {
                            host => $hostObj->{name},
                            name => 'check_printer_up',
                            action => \&check_printer_up,
                            repeat => 1
                        };
                    } elsif ($hostObj->{type} eq 'camera') {
                        push @actions, {
                            host => $hostObj->{name},
                            name => 'check_camera_up',
                            action => \&check_camera_up,
                            repeat => 1
                        };
                    } else { # web, mail, nfs (nfs device status)
                        push @actions, {
                            host => $hostObj->{name},
                            name => 'check_nfs_up',
                            action => \&check_nfs_up,
                            repeat => 1
                        };
                    }
                }

                if ($hostObj->{name} eq $::host) {
                    $index = $total;
                    if (exists $hostObj->{localDisks}) {
                        push @actions, {
                            host => $hostObj->{name},
                            name => 'check_local_disks',
                            action => \&check_local_disks,
                            repeat => 15
                        };
                    }
                    push @actions, {
                        host => $hostObj->{name},
                        name => 'check_computer_specs',
                        action => \&check_computer_specs,
                        repeat => 0
                    };
                    push @actions, {
                        host => $hostObj->{name},
                        name => 'check_computer_up',
                        action => \&check_computer_up,
                        repeat => 1
                    };
                }
            }
        } else {
            pr_log("$hostObj->{name} object is invalid.\n");
            exit 1;
        }
    }
} else {
    pr_log("static-setup.json object is invalid.\n");
    exit 1;
}

wait_offset($index, $total);

$::cmds = [];

lock_file($::network_folder . '/data.json');
$::dyn_data = read_json_file($::network_folder . '/data.json');
if (not validate_hash($::dyn_data, { hosts => 'ARRAY' })) {
    pr_log("Dynamic data.json file does not have a 'hosts' array. Clearing and resetting.\n");
    $::dyn_data = { hosts => [ ] };
}

foreach my $action (@actions) {
    if ($action->{repeat} == 0) {
        eval {
            $action->{action}->($action->{host}) 
        };

        if ($@) {
            pr_log("A fatal error has occurred calling $action->{name}(\"$action->{host}\")\n");
            warn $@ if $::is_debug;
        }
    }
}

while (1) {
    foreach my $action (@actions) {
        if ($action->{repeat} > 0 and
            dyn_cache_timeout("action.$action->{name}", $action->{host}, $action->{repeat} * $_TIME_S_MINUTE)) {
            eval {
                $action->{action}->($action->{host}) if $action->{repeat};
            };

            if ($@) {
                pr_log("A fatal error has occurred calling $action->{name}(\"$action->{host}\"): $!\n");
                warn $@ if $::is_debug;
            }
        }
    }

    write_json_file($::network_folder . '/data.json', $::dyn_data);
    unlock_file($::network_folder . '/data.json');

    # run commands deferred until after we've unlocked data.json, i.e. starting other scripts
    # run one command per iteration
    deferred_cmd_run();

    sleep 3;
    wait_offset($index, $total);

    lock_file($::network_folder . '/data.json');
    $::dyn_data = read_json_file($::network_folder . '/data.json');
    if (not validate_hash($::dyn_data, { hosts => 'ARRAY' })) {
        pr_log("Dynamic data.json file does not have a 'hosts' array. Clearing and resetting.\n");
        $::dyn_data = { hosts => [ ] };
    }
}

# read the given JSON file and return the object
sub read_json_file {
    my $file = shift;
    if (open my $fh, '<', $file) {
        local $/;
        my $contents = <$fh>;
        close $fh;
        return decode_json $contents;
    } else {
        return undef;
    }
}

# write the given object to the given file as JSON
sub write_json_file {
    my $file = shift;
    my $object = shift;
    if (open my $fh, '>', $file) {
        print $fh (encode_json $object);
        close $fh;
        return 1;
    } else {
        return 0;
    }
}

sub lock_file {
    my $file = shift;
    while (open my $fh, '<', "$file.lock") {
        local $/;
        my $otherhost = <$fh>;
        close $fh;
        if (not defined $otherhost or $otherhost eq '') {
            sleep 1;
            next;
        }
        last if $otherhost eq $::host;
        pr_log("Waiting for lock held by $otherhost to write to $file...\n");
        sleep 1;
    }
    if (open my $fh, '>', "$file.lock") {
        print $fh $::host;
        close $fh;
        return 1;
    } else {
        return 0;
    }
}

sub unlock_file {
    my $file = shift;
    unlink "$file.lock";
}

sub dyn_data_get_host {
    my $hname = shift;
    foreach my $hostObj (@{$::dyn_data->{hosts}}) {
        if (exists $hostObj->{name} and $hostObj->{name} eq $hname) {
            return $hostObj;
        }
    }
    my $newHostObj = {
        name => $hname,
        state => 'Down',
        icon => 'unk'
    };
    push @{$::dyn_data->{hosts}}, $newHostObj;
}

sub sta_data_get_host {
    my $hname = shift;
    foreach my $hostObj (@{$::sta_data->{hosts}}) {
        if (exists $hostObj->{name} and $hostObj->{name} eq $hname) {
            return $hostObj;
        }
    }
    pr_log("Static data does not describe $hname! Aborting.\n");
    exit 1;
}

sub validate_hash {
    my $object = shift;
    my $check = shift;
    if (ref $object eq 'HASH') {
        foreach my $el (keys %$check) {
            if (not (($check->{$el} eq 'SCALAR' and
                ref $object->{$el} eq '') or
                ref $object->{$el} eq $check->{$el})) {
                return 0;
            }
        }
        return 1;
    } else {
        return 0;
    }
}

sub pr_log {
    my $out = shift;
    $out = "[$::host] $out";
    print $out if ($::is_debug or not $::is_forked);
    if (not (-d "$::network_folder/logs")) {
        mkdir "$::network_folder/logs", 0755;
    }
    if (open my $fh, '>>', "$::network_folder/logs/$::host") {
        print $fh $out;
        close $fh;
    }
}

sub daemonize {
    return 1 if ($::is_debug);
    my $pid = fork;
    if ($pid < 0) {
        print STDERR "Could not separate from shell because fork() failed: $!\n";
        return 0;
    }
    $pid and exit;
    setsid;
    close STDIN;
    close STDOUT;
    close STDERR;
    return 1;
}

sub check_computer_specs {
    my $name = shift;
    my $data = dyn_data_get_host($name);
    #pr_log("HOST: $name, FN: check_computer_specs\n");

    my $os = { class => 'unknown', version => -1 };
    my $uname = alarm_cmd('uname -a');
    my $sunos = 0;
    if ($uname =~ m/\.fc(\d+)/) {
        $os = { class => 'fedora', version => $1 + 0, releaseFile => '/etc/fedora-release' };
    } elsif ($uname =~ m/\.el(\d+)/) {
        $os = { class => 'rhel', version => $1 + 0, releaseFile => '/etc/redhat-release' };
    } elsif ($uname =~ m/^SunOS/) {
        $sunos = 1;
        $os = { class => 'sunos', version => -1, releaseFile => '/etc/release' };
    }
    if (exists $os->{releaseFile}) {
        if (open my $relfh, '<', $os->{releaseFile}) {
            my $rel = <$relfh>;
            close $relfh;
            if ($sunos) {
                $rel =~ m/Solaris (\d+)/;
                $os->{version} = $1 + 0;
            }
            $rel =~ s/^\s+|\s+$//g;
            $os->{release} = $rel;
            chomp $os->{release};
        }
    }

    # populate cpu
    my $cpu;
    if ($sunos) {
        # set cpu.model, cpu.cores, cpu.threads, and cpu.speed
        my $prtdiag = alarm_cmd('/usr/sbin/prtdiag');
        my @lines = split m/\n/, $prtdiag;
        my $cpu_p = {};
        foreach my $line (@lines) {
            if ($line =~ m/^(\d+)\s+(\d+)\sMHz\s+(\S+)\s+on-line\s*$/) {
                (my $n, my $mhz, my $name) = ($1, $2, $3);
                $cpu_p->{model} = $name;
                chomp $cpu_p->{model};
                $cpu_p->{model_clean} = $cpu_p->{model};
                $cpu_p->{model_clean} =~ s/SUNW,//;
                $cpu_p->{threads} = $n + 1;
                $cpu_p->{cores} = ($n + 1) / 4;
                $cpu_p->{speed} = $mhz + 0;
            }
        }

        $cpu = [ $cpu_p ];
        
        # set mem.total
        my $mem_m;
        my $prtconf = alarm_cmd('/usr/sbin/prtconf | head -n 2');
        if ($prtconf =~ m/Memory size: (\d+) Megabytes/) {
            $mem_m = { name => 'main', total => $1 * 1024, used => -1 };
        }
        delete $data->{mem} if exists $data->{mem};
        $data->{main_mem} = $mem_m;
    } else {
        # set cpu.model, cpu.cores, cpu.threads, and cpu.speed
        my $cpu_info = alarm_cmd('cat /proc/cpuinfo');
        my $cpu_c;
        my $cpu_model;
        my $cpu_speed;
        my $cpu_p_index;
        my $cpu_c_index;
        $cpu = {};
        my @lines = split /\n/, $cpu_info;
        foreach my $line (@lines) {
            if ($line =~ m/([^:]+):\s+(.*)/) {
                my $cpu_field = $1;
                my $cpu_value = $2;

                $cpu_field =~ s/\s*$//;
                $cpu_field =~ s/^\s*//;
                $cpu_value =~ s/\s*$//;

                if ($cpu_field eq 'processor') {
                    # start of new proc info
                    if (defined $cpu_c) {
                        my $ht = 1;
                        if (exists $cpu->{$cpu_p_index}->{$cpu_c_index}) {
                            # hyperthreaded
                            $ht = $cpu->{$cpu_p_index}->{$cpu_c_index}->{hyperthreads} + 1;
                        }
                        $cpu->{$cpu_p_index}->{$cpu_c_index} = $cpu_c;
                        $cpu->{$cpu_p_index}->{$cpu_c_index}->{hyperthreads} = $ht;
                    }
                    $cpu_c = { index => $cpu_value + 0, dict => {} };
                } elsif ($cpu_field eq 'model name') {
                    $cpu_model = $cpu_value;
                    $cpu_c->{model} = $cpu_model;
                    $cpu_c->{model_clean} = $cpu_model;
                    $cpu_c->{model_clean} =~ s/\bCPU\b|\s@\s|\b[\d.]+\s?[TGM]Hz\b//g;
                    $cpu_c->{model_clean} =~ s/(\s)\s+/$1/g;
                    $cpu_c->{model_clean} =~ s/^\s//;
                    $cpu_c->{model_clean} =~ s/\s$//;
                } elsif ($cpu_field eq 'cpu MHz') {
                    $cpu_speed = $cpu_value + 0;
                    $cpu_c->{speed} = $cpu_speed;
                } elsif ($cpu_field eq 'physical id') {
                    $cpu_p_index = $cpu_value + 0;
                    $cpu_c->{p_index} = $cpu_p_index;
                } elsif ($cpu_field eq 'core id') {
                    $cpu_c_index = $cpu_value + 0;
                    $cpu_c->{c_index} = $cpu_c_index;
                }
            }
        }

        # add last core
        if (defined $cpu_c) {
            my $ht = 1;
            if (exists $cpu->{$cpu_p_index}->{$cpu_c_index}) {
                # hyperthreaded
                $ht = $cpu->{$cpu_p_index}->{$cpu_c_index}->{hyperthreads} + 1;
            }
            $cpu->{$cpu_p_index}->{$cpu_c_index} = $cpu_c;
            $cpu->{$cpu_p_index}->{$cpu_c_index}->{hyperthreads} = $ht;
        }

        # remove unnecessary data by converting to arrays
        my $cpu_arr = [];
        foreach my $p_index (keys %$cpu) {
            my $c_index_any;
            my $c_num = 0;
            foreach my $c_index (keys %{$cpu->{$p_index}}) {
                $c_index_any = $c_index if not defined $c_index_any;
                $c_num += $cpu->{$p_index}->{$c_index}->{hyperthreads};
            }
            my $cpu_p = {
                model => $cpu->{$p_index}->{$c_index_any}->{model},
                model_clean => $cpu->{$p_index}->{$c_index_any}->{model_clean},
                speed => $cpu->{$p_index}->{$c_index_any}->{speed},
                threads => $c_num,
                ht_per_core => $cpu->{$p_index}->{$c_index_any}->{hyperthreads},
                physical_id => $p_index + 0
            };
            push @$cpu_arr, $cpu_p;
        }

        $cpu = $cpu_arr;
    }

    $data->{os} = $os;
    $data->{cpu} = $cpu;
    $data->{icon} = $data->{os}->{class};
}

sub check_computer_up {
    my $name = shift;
    my $data = dyn_data_get_host($name);
    my $current_ts = time;
    #pr_log("HOST: $name, FN: check_computer_up\n");

    my $uptime = alarm_cmd('uptime');
    $uptime =~ m#.*up (?:(\d+) day\(?s?\)?, )?\s?(?:(\d+)(?::| hr\(?s?\)?))?(\d+)(?: min\(?s?\)?)?, \s?(\d+) users?.*#;
    my @up = ( 0, 0, 0 );
    $up[0] = $1 if defined($1);
    $up[1] = $2 if defined($2);
    $up[2] = $3 if defined($3);
    my $up_seconds = $up[0] * $_TIME_S_DAY + $up[1] * $_TIME_S_HOUR + $up[2] * $_TIME_S_MINUTE;
    #pr_log("Up for $up[0] days, $up[1] hours, and $up[2] minutes.\n");

    my $users = [];
    my $who = alarm_cmd('who');
    while ($who =~ m#(\S+)\s+(\S+)\s+(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}|\S{3}\s+\d+\s+\d+:\d{2})(\s+\(\S+\)|).*#g) {
        my $user = { netid => $1, tty => $2, loginTimeString => $3, host => $4 };
        # get date
        # solaris style:
        if ($user->{loginTimeString} =~ m#(\S{3})\s+(\d+)\s+(\d+):(\d{2})#) {
            $user->{loginTimeString} = currY().'-'.m2n($1)."-$2 $3:$4:00";
        }
        # get timestamp
        my @login_time = $user->{loginTimeString} =~
            m/(\d{4})-(\d{2})-(\d{2})\s(\d{2}):(\d{2})/;
        $login_time[1]--; # 0-based month value
        my $login_time_s = timelocal 0,@login_time[4,3,2,1,0];
        $user->{loginTime} = $login_time_s;
        # get host
        $user->{host} = $1 if $user->{host} =~ m#\s\((\S+)\)#;
        $user->{host} = '*' if length($user->{host}) == 0;
        # check for user folder
        $user->{folderExists} = dyn_cache(sub {
                if (defined $user->{netid}) {
                    return defined (-d "/u/www/u/$user->{netid}");
                } else {
                    return 0;
                }
            }, 'folderExists', $user->{netid}, $_TIME_S_DAY);
        # get real name
        $user->{name} = dyn_cache(sub {
                my $finger = alarm_cmd("finger -ms $user->{netid}");
                if ($finger =~ m#$user->{netid}\s+((?:[^\s:]+\s)*[^\s:]+)\s+#) {
                    return $1;
                } else {
                    return $user->{netid};
                }
            }, 'fingerName', $user->{netid}, $_TIME_S_DAY);
        push @$users, $user;
    }

    # set memory data (will fail on SunOS)
    my $mem_s; my $mem_m;
    my $mem_info = alarm_cmd('free');
    if ($mem_info =~ m/Mem:\s+(\d+)\s+(\d+)\s+(\d+)/) {
        $mem_m = { name => 'main', total => $1 + 0, used => $2 + 0 };
    }
    if ($mem_info =~ m/Swap:\s+(\d+)\s+(\d+)\s+(\d+)/) {
        $mem_s = { name => 'swap', total => $1 + 0, used => $2 + 0 };
    }

    $data->{users} = $users;
    delete $data->{mem} if exists $data->{mem};
    $data->{main_mem} = $mem_m if defined $mem_m;
    $data->{swap_mem} = $mem_s if defined $mem_s;
    $data->{state} = 'Up';
    $data->{lastChange} = $current_ts - $up_seconds;
    $data->{lastCheck} = $current_ts;
    $data->{icon} = $data->{os}->{class} if exists $data->{os};
}

sub dyn_cache {
    my $fn_reeval = shift;
    my $cache_prefix = shift;
    my $cache_id = shift;
    my $cache_timeout = shift;
    my $cache_key = "$cache_prefix:$cache_id";

    if (not exists $::dyn_data->{cache}) {
        $::dyn_data->{cache} = {};
    }
    my $cache_obj = $::dyn_data->{cache};
   
    if (not exists $cache_obj->{$cache_key}) {
        $cache_obj->{$cache_key} = {
            value => $fn_reeval->(),
            timestamp => time
        };
    }
    my $cache_line = $cache_obj->{$cache_key};
    if ($cache_line->{timestamp} < time - $cache_timeout) {
        $cache_line->{value} = $fn_reeval->();
        $cache_line->{timestamp} = time;
    }
    return $cache_line->{value};
}

sub dyn_cache_timeout {
    my $cache_prefix = shift;
    my $cache_id = shift;
    my $cache_timeout = shift;
    my $cache_key = "$cache_prefix:$cache_id";

    if (not exists $::dyn_data->{cache}) {
        $::dyn_data->{cache} = {};
    }
    my $cache_obj = $::dyn_data->{cache};
   
    if (not exists $cache_obj->{$cache_key}) {
        $cache_obj->{$cache_key} = {
            timestamp => time
        };
        return 1;
    }
    my $cache_line = $cache_obj->{$cache_key};
    if ($cache_line->{timestamp} < time - $cache_timeout) {
        $cache_line->{timestamp} = time;
        return 1;
    }
    return 0;
}

sub check_computer_timeout {
    my $name = shift;
    my $data = dyn_data_get_host($name);
    my $current_ts = time;
    #pr_log("HOST: $name, FN: check_computer_timeout\n");

    my $lcheck, my $lchange, my $up_seconds;
    $lcheck = $data->{lastCheck} if exists $data->{lastCheck};
    $lchange = $data->{lastChange} if exists $data->{lastChange};

    $up_seconds = $current_ts - $lchange if defined $lchange;

    if (not defined $lcheck or $current_ts - $lcheck > $_TIME_IS_DOWN) {
        if ($data->{state} eq 'Up') {
            $data->{lastChange} = $lcheck + $_TIME if defined $lcheck;
            $data->{lastCheck} = $current_ts;
            $data->{state} = 'Down';
        }

        # try to re-start it!
        if (dyn_cache_timeout('hostInit', $name, $_TIME_IS_DOWN)) {
            pr_log("Initializing script on remote host $name (deferred)...\n");
            deferred_cmd_add("ssh $name \"".
                "pkill infobox; ".
                "cd /u/www/ugc/netsp; ".
                "PERL5LIBS=/u/www/ugc/perl5 ./infobox.pl --slave --net $::network_folder\"");
        }
    }
}

sub check_local_disks {
    my $name = shift;
    #pr_log("HOST: $name, FN: check_local_disks\n");

    check_disks($name, 'local');
}

sub check_nfs_disks {
    my $name = shift;
    #pr_log("HOST: $name, FN: check_nfs_disks\n");

    check_disks($name, 'nfs');
}

sub check_disks {
    my $name = shift;
    my $disk_type = shift;
    my $data = dyn_data_get_host($name);
    my $sta_data = sta_data_get_host($name);
    my $current_ts = time;

    my $disks = [];
    my @disk_list = @{$sta_data->{"${disk_type}Disks"}};
    my $disk_df = alarm_cmd("df --output=target,size,used @disk_list");
    while ($disk_df =~ m/(\S+)\s+(\d+)\s+(\d+)/g) {
        (my $path, my $total, my $used) = ($1, $2 + 0, $3 + 0);
        push @$disks, { path => $path, total => $total, used => $used };
    }
    $data->{disks} = $disks;
    $data->{lastCheck} = $current_ts;
}

sub check_printer_up {
    my $name = shift;
    my $data = dyn_data_get_host($name);
    my $current_ts = time;
    #pr_log("HOST: $name, FN: check_printer_up\n");
    
    ( my $success, my $text, my $model, my $inks, my $trays ) = alrmpjsw($name);
    my $changed = 0;
    if ($success) {
        $changed = 1 if $data->{state} eq 'Down';
        $data->{state} = 'Up';

        $data->{prText} = $text;
        chomp $data->{prText};
        $data->{prModel} = $model;
        chomp $data->{prModel};
        $data->{inks} = $inks;
        $data->{trays} = $trays;
    } else {
        $changed = 1 if $data->{state} eq 'Up';
        $data->{state} = 'Down';
    }
    $data->{lastChange} = $data->{lastCheck} + $_TIME if $changed and defined $data->{lastCheck};
    $data->{lastCheck} = $current_ts;
    $data->{icon} = 'hp';
}

sub check_camera_up {
    my $name = shift;
    my $data = dyn_data_get_host($name);
    my $sta_data = sta_data_get_host($name);
    my $current_ts = time;
    #pr_log("HOST: $name, FN: check_camera_up\n");
    
    (undef,undef,undef,undef,undef,undef,undef,undef, my $mtime) =
        stat "/u/www$sta_data->{webLocation}";
    #pr_log("Camera $name mtime = $mtime\n");

    my $changed = 0;
    if ($mtime < $current_ts - $_TIME_IS_DOWN) {
        $changed = 1 if $data->{state} eq 'Up';
        $data->{state} = 'Down';
    } else {
        $changed = 1 if $data->{state} eq 'Down';
        $data->{state} = 'Up';
    }
    $data->{lastChange} = $mtime + 0 if $changed;
    $data->{lastCheck} = $current_ts;
    $data->{icon} = 'cam';
}

sub check_nfs_up {
    my $name = shift;
    my $data = dyn_data_get_host($name);
    my $sta_data = sta_data_get_host($name);
    #pr_log("HOST: $name, FN: check_nfs_up\n");

    $data->{state} = 'Up';
    $data->{icon} = $sta_data->{type} if not exists $data->{icon};
}

# executes a shell command with a timeout
sub alarm_cmd {
    my $cmd = shift;
    my $result = '';
    my $pid = open PROC, "$cmd |" or die $!;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n"; };
        alarm $_CMD_TIMEOUT;
        $result .= $_ while <PROC>;
        while (<PROC>) {$result .= $_;}
        close PROC;
        alarm 0;
    };
    if ($@) {
        kill 9 => $pid;
        close PROC;
        unless ($@ eq "timeout\n") {
            pr_log("Operation failed ($cmd): $!\n");
            #kill TERM => $pid unless (kill 0 => $pid); # forceful close PROC
        } else {
            pr_log("Operation timed out ($_CMD_TIMEOUT seconds): $cmd\n");
        }
        return '';
    } else {
        #print $cmd.'=>'.$result;
        return $result;
    }
}

# add a command to the set of deferred commands
sub deferred_cmd_add {
    my $cmd = shift;
    foreach my $otherCmd (@$::cmds) {
        # do not add if duplicate
        return if $otherCmd eq $cmd;
    }
    push @$::cmds, $cmd;
}

# run a single command
sub deferred_cmd_run {
    if (@$::cmds) {
        eval {
            my $cmd = shift @$::cmds;
            pr_log("Running deferred command: $cmd\n");
            my $result = alarm_cmd($cmd);
            chomp $result;
            pr_log("Command result: $result\n");
        };

        if ($@) {
            pr_log("A fatal error has occurred running the command: $!\n");
            warn $@ if $::is_debug;
        }
        return 1;
    } else {
        return 0;
    }
}

# gets printer status (via pjstatus system) with a timeout
##ub alrmpjs {
#    my $online = 0;
#    my $status = [];
#
#    my $proto = getprotobyname("tcp");
#    socket SOCK, PF_INET, SOCK_STREAM, $proto
#        or do { plog("[$host] Socket: $!\n"); return ( 0, [] ); };
#
#    eval {
#        local $SIG{ALRM} = sub { die "timeout\n"; };
#        alarm $TIMEOUT;
#        my $port = 9100;
#        my $iaddr = inet_aton($host) or die "[$host] Unable to resolve: $!";
#        my $paddr = sockaddr_in($port, $iaddr);
#        connect SOCK, $paddr
#            or do { plog("[$host] Connect: $!\n"); return ( 0, [] ); };
#        SOCK->autoflush(1);
#        my $request = "\e%-12345X\@PJL \r\n\@PJL INFO STATUS \r\n\e%-12345X";
#        #print `echo -n "$request" | hexdump -C`;
#        print SOCK $request;
#        my $code = 0;
#        my $idx = 1;
#        while (my $line = <SOCK>) {
#            #print $line;
#            #print `echo -n "$line" | hexdump -C`;
#            if ($line =~ /CODE(\d+|)=(\d+)\r\n/) {
#                $code = int $2;
#                $idx = $1;
#                $idx = 1 if length($idx) == 0;
#            } elsif ($line =~ /DISPLAY(\d+|)="(.*)"\r\n/) {
#                $idx = $1;
#                $idx = 1 if length($idx) == 0;
#                push @$status, "$code $2";
#            } elsif ($line eq "ONLINE=TRUE\r\n") {
#                $online = 1;
#                last;
#            } elsif ($line eq "ONLINE=FALSE\r\n") {
#                $online = 0;
#                last;
#            }
#        }
#        close SOCK;
#        alarm 0;
#    };
#    if ($@) {
#        close SOCK;
#        my $op = "PJSTATUS $host";
#        unless ($@ eq "timeout\n") {
#            plog("[$host] Operation failed ($op): $!\n");
#        } else {
#            plog("[$host] Operation timed out ($TIMEOUT seconds): $op\n");
#        }
#        return ( 0, [] );
#    } else {
#        return ( $online, $status );
#    }
#    return ( $online, $status );
#}

# scrapes the webpage for the printer for ink and paper info with a timeout
sub alrmpjsw {
    my $prhost = shift;
    my $success = 1;
    my $state = '';
    my $model = '';
    my $inklvl = [];
    my $pprlvl = [];
    
    my $web_content = alarm_cmd("curl -sL http://$prhost/hp/device/this.LCDispatcher");
    
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

sub wait_offset {
    #sleep 5;
    #pr_log("DEBUG: Running now...\n");
    #return;
    my $index = shift;
    my $total = shift;
    # offset self by ~3 seconds from other running scripts, by order in static_setup.json
    if ($index > 0 && $total >= $index) {
        my $t3 = $total * 3;
        my $t_in_cycle = time % $t3;
        $_TIME = $t3;
        my $offset = $index * 3 - $t_in_cycle;
        $offset += $t3 if $offset < 0;
        sleep $offset;
    }
}


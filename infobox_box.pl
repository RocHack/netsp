#!/bin/perl

use strict;
use warnings;
use Sys::Hostname;

my $TIME = 600;

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
my $file = "data/$host";

my $uptime = `uptime`;
$uptime =~ m#.*up (?:(\d+) day\(?s?\)?, )?\s?(?:(\d+):)?(\d+)(?: min)?, \s?(\d+) users?.*#;
my @up = ( int $1, int $2, int $3 );

if (not -e $file) {
    open FILE, '>', $file
        or exit "Cannot create $file: $!\n";
    close FILE;
    chmod 0644, $file;
    print "[$host] File created.\n";
}

my $users;

sub m2n {
    return $mons{$1};
}

while (1) {
    print "[$host] Up for $up[0] days, $up[1] hours, and $up[2] minutes.\n";
    my $changes = 0;

    my $new_users = [];
    my $who = `who`;
    while ($who =~ m#(\S+)\s+(pts/\d+|tty\d+|\:\d+)\s+(\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}|\S{3}\s\d{2}\s\d{2}:\d{2})(\s\(\S+\)|).*#g) {
        my $arr = [ $1, $2, $3, $4 ];
        if ($arr->[2] =~ m#(\S{3})\s(\d{2})\s(\d{2}):(\d{2})#) {
            $arr->[2] = "$year-".m2n($1)."-$2 $3:$4:00";
        }
        if ($arr->[3] =~ m#\s\((\S+)\)#) {
            $arr->[3] = $1;
        }
        push @$new_users, $arr;
    }

    $changes++ if $#{$new_users} != $#{$users};
    $users = $new_users;

    if ($changes > 0) {
        print "[$host] There are ".($#{$users}+1)." users on now.\n";
    }

    open FILE, '>', $file
        or print "Cannot open $file: $!\n";

    print FILE "$up[0]:$up[1]:$up[2]:".($#{$users}+1)."\n";
    foreach my $user (@{$users}) {
        print FILE "$user->[0] $user->[1] $user->[2] $user->[3]\n";
    }

    close FILE;
    
    sleep $TIME;
    $up[2] += $TIME / 60;
    if ($up[2] >= 60) {
        $up[2] -= 60;
        $up[1] += 1;
        if ($up[1] >= 24) {
            $up[1] -= 24;
            $up[0] += 1;
        }
    }
}


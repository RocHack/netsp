<?php

//error_reporting(E_ALL);
//ini_set('display_errors', '1');

function do_die() {
    header('Location: ../csugnet.html');
    exit;
}

header('Content-Type: text/html; charset=utf-8');

function parse_session($tty, $from, $login_date, $login_time) {
    $result = '';
    if ($tty[0] == ':' && $from == '') {
        $tty = substr($tty, 1);
        $result = "<b>login :$tty</b>";
    } elseif (substr($tty, 0, 3) == 'tty' && $from == '') {
        $tty = substr($tty, 3);
        $result = "<b>ctrl-alt-f$tty</b>";
    } elseif (substr($tty, 0, 4) == 'pts/') {
        $tty = substr($tty, 4);
        $matches = array();
        $sfrom = $from;
        if (preg_match(',^:(\S+):S.(\d+)$,', $from, &$matches)) {
            $sfrom = $matches[1];
            if ($sfrom[0] == ':') {
                $sfrom = substr($sfrom, 1);
                $sfrom = "<b>login :$sfrom</b>";
            } elseif (substr($sfrom, 0, 3) == 'tty') {
                $sfrom = substr($sfrom, 3);
                $sfrom = "<b>ctrl-alt-f$sfrom</b>";
            } elseif (substr($sfrom, 0, 4) == 'pts/') {
                $sfrom = substr($sfrom, 4);
                $sfrom = "<b>pts/$sfrom</b>";
            }
            $sfrom = "<b>screen $matches[2]</b> from $sfrom";
        } elseif (preg_match(',^:(\d+)$,', $from, &$matches)) {
            $sfrom = "<b>terminal</b> from <b>login :$matches[1]</b>";
        } elseif (preg_match(',^localhost:(\d+)\.(\d+)$,', $from, &$matches)) {
            $sfrom = "<b>x-forwarded terminal</b> from <b>localhost:$matches[1].$matches[2]</b>";
        } else {
            if (preg_match(',^(\S+)\.csug\.rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>$matches[1]</b>.csug.rochester.edu";
            } elseif (preg_match(',^(\S+)\.cs\.rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>$matches[1]</b>.cs.rochester.edu";
            } elseif (preg_match(',.*resnet\.rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>UR resnet</b>";
            } elseif (preg_match(',.*cc\.rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>UR ITS</b>";
            } elseif (preg_match(',.*rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>UR</b>";
            } elseif (preg_match(',^10\.\d+\.\d+\.\d+$,', $from, &$matches)) {
                $sfrom = "<b>UR WiFi</b>";
            } elseif (preg_match(',^128\.151\.\d+\.\d+$,', $from, &$matches)) {
                $sfrom = "<b>UR</b> address $from";
            } elseif (preg_match(',^\d+\.\d+\.\d+\.\d+$,', $from, &$matches)) {
                $sfrom = "address $from";
            } elseif (preg_match(',.*?([^\.]+\.[^\.]+)$,', $from, &$matches)) {
                $sfrom = "domain <b>$matches[1]</b>";
            }
            $sfrom = "<b>ssh</b> from $sfrom";
        }
        $result = "$sfrom as <b>pts/$tty</b>";
    } else {
        $result = "<b>$from</b> as <b>$tty</b> (unknown)";
    }

    $login_arr = strptime("$login_date $login_time", '%Y-%m-%d %H:%M') or print('date parse failed<br />');
    $login = mktime($login_arr['tm_hour'],
                    $login_arr['tm_min'],
                    0,
                    $login_arr['tm_mon'] + 1,
                    $login_arr['tm_mday'],
                    $login_arr['tm_year'] + 1900);
    $time = std_date($login, time());
    return "<span title=\"$from\">on $result since $time</span>";
}

function html_san($in) {
    return htmlentities($in, ENT_NOQUOTES);
}

function pl($num) {
    return $num == 1 ? '' : 's';
}

function std_date($uts, $uts_now, $show_sec = false) {
    $s = ($uts_now - $uts);
    if ($s < 0) $s = 0;
    $m = $s / 60;
    $h = $m / 60;
    $d = $h / 24;
    $s = $s % 60;
    $m = $m % 60;
    $h = $h % 24;
    $d = floor($d);
    if ($show_sec) {
        $t = "$s second".pl($s);
        if ($m > 0) $t = "$m minute".pl($m).", $t";
    } else {
        $t = "$m minute".pl($m);
    }
    if ($h > 0) $t = "$h hour".pl($h).", $t";
    if ($d > 0) $t = "$d day".pl($d).", $t";
    $sarg = '';
    if ($show_sec) $sarg = ':s';
    return date("g:i{$sarg}a D, M j, Y ", $uts) . " ($t ago)";
}

$id = isset($_GET['id']) ? html_san($_GET['id']) : do_die();

$now = time();
$items = array();
if (substr($id, 0, 4) == 'box_') {
    $box = substr($id, 4);
    $file = "data/$box";
    if (file_exists($file)) {
        // file and uptime info
        $filemtime = filemtime($file);
        $data = mb_convert_encoding(file_get_contents($file), 'auto', 'UTF-8');
        $lines = explode("\n", $data);
        $info_line = array_shift($lines);
        $info = explode(":", $info_line);
        if (strlen($info_line) == 0) {
            // empty file
            $uptime = $now + 1000;
        } else {
            $uptime = $filemtime - $info[2] * 60
                                 - $info[1] * 60 * 60
                                 - $info[0] * 60 * 60 * 24;
        }

        // user session info
        $unqu = 0;
        $sess_count = 0;
        //$logu = 0;
        //$ttyu = 0;
        $udata = array();
        foreach ($lines as $line) {
            if (strlen($line) > 0 && $line[0] != '.') {
                $fields = explode(' ', $line, 6);
                /*$tty = $fields[1];
                if (substr($tty, 0, 1) == ':') {
                    $logu++;
                } elseif (substr($tty, 0, 3) == 'tty') {
                    $ttyu++;
                }*/
          
                if (array_key_exists($fields[0], $udata)) {
                    $udata[$fields[0]][] = $fields;
                } else {
                    $udata[$fields[0]] = array($fields);
                    $unqu++;
                }
                $sess_count++;
            }
        }
        $ulist = '';
        foreach ($udata as $uname => $sess_arr) {
            if (strlen($ulist) == 0) $ulist = '<ul>';
            $ufname = $uname;
            $uinfo = '<br />';
            foreach ($sess_arr as $idx => $sess) {
                $ufname = isset($sess[5]) ? (strlen($sess[5]) > 0 ? $sess[5] : $uname) : $uname;
                $uinfo .= parse_session($sess[1], $sess[4] == '*' ? '' : $sess[4], $sess[2], $sess[3]);
                if ($idx < count($sess_arr) - 1) {
                    $uinfo .= '<br />';
                }
            }
            $ulist .= "<li><a href=\"http://csug.rochester.edu/u/$uname/\" title=\"".htmlentities($uname)."\" target=\"_blank\">$ufname</a>$uinfo</li>";
        }
        if (strlen($ulist) > 0) $ulist .= '</ul>';

        // disk info
        $disk_count = 0;
        $disk_list = '';
        $dlist = '';
        if (isset($info[3]) && strlen($info[3]) > 0 && strpos($info[3], ';') !== false) {
            $disks = explode(';', $info[3]);
            foreach ($disks as $disk) {
                if (strlen($disk) > 0) {
                    $disk_data = explode(',', $disk);
                    if ($disk_data[1] == '1') {
                        $disk_count++;
                        $disk_list .= '<span title="'.htmlentities($disk_data[2]).'">'.htmlentities($disk_data[0]) . '</span>, ';
                    }
                }
            }
            if (strlen($disk_list) > 0) {
                $disk_list = substr($disk_list, 0, -2);
                $dlist = " ($disk_list)<ul>";
                foreach ($disks as $disk) {
                    if (strlen($disk) > 0) {
                        $disk_data = explode(',', $disk);
                        if ($disk_data[1] == '1') {
                            if (isset($disk_data[3])) {
                                $status = " is mounted with $disk_data[4] of $disk_data[3] used ($disk_data[6])";
                                $dlist .= "<li title=\"$disk_data[2]\"><b>$disk_data[0]</b>$status<div class=\"prog\"><div class=\"prog_usage\" style=\"width: $disk_data[6];\"></div></li>";
                            }
                        }
                    }
                }
                $dlist .= '</ul>';
            }
        }

        // print to array
        if (substr($info_line, 0, 9) == '-1:-1:-1:') {
            $items[] = '<span class="offline">This computer is offline</span>';
        } elseif ($uptime > $now) {
            $items[] = '<span class="online_old">This computer may be offline (empty file)</span>';
            $items[] = 'Last updated: '.std_date($filemtime, $now, true);
        } else {
            $is_server = false;
            if (substr($info_line, 0, 6) == '0:0:0:') {
                $is_server = true;
            }
            if ($now - $filemtime > 600) {
                $items[] = '<span class="online_old">This computer may be offline (no response for 10 minutes)</span>';
            } else {
                $items[] = '<span class="online">This computer is online</span>';
            }
            if (!$is_server) {
                $items[] = "Sessions: $sess_count online ($unqu unique user".pl($unqu).')'.$ulist;
            } else {
                $items[] = 'This computer is a server and is being queried remotely.';
            }
            // $logu (local login".pl($logu)."), $ttyu (on ctrl-alt-f#);
            $items[] = "Disks: $disk_count mounted$dlist";
            if (!$is_server) {
                $items[] = 'Up since: '.std_date($uptime, $now);
            }
            $items[] = 'Last updated: '.std_date($filemtime, $now, true);
        }
    } else {
        $items[] = '<span class="offline">No data</span>';
    }
    $header = "Computer Info for <img src=\"csugnet/$info[4].png\" width=\"16\" height=\"16\" title=\"".htmlentities($info[6])."\" alt=\"".htmlentities($info[6])."\" /> <span title=\"$info[6]\">$box</span>";
} elseif (substr($id, 0, 4) == 'prn_') {
    $prn = substr($id, 4);
    $header = "Printer Info for $prn";
    $file = "data/$prn";
    if (file_exists($file)) {
        $filemtime = filemtime($file);
        $data = file_get_contents($file);
        $lines = explode("\n", $data);
        $info_line = array_shift($lines);
        $info = explode(":", $info_line);
        $uptime = $filemtime - $info[2] * 60
                             - $info[1] * 60 * 60
                             - $info[0] * 60 * 60 * 24;
        if ($info[3] != '1') {
            $items[] = '<span class="offline">This printer is offline</span>';
        } elseif ($now - $filemtime > 600) {
            $items[] = '<span class="online_old">This printer may be offline (no response for 10 minutes)</span>';
        } else {
            $items[] = '<span class="online">This printer is online</span>';
        }
        foreach ($lines as $i => $line) {
            if (strpos($line, '=') !== false) {
                list($key, $value) = explode('=', $line, 2);
                $value = html_san($value);
                switch ($key) {
                case 'STATUS_1':
                case 'STATUS_2':
                    list($code, $status) = explode(' ', $value, 2);
                    $items[] = "<span title=\"$code\"><b>$status</b></span>";
                    break;
                case 'TRAY_1':
                case 'TRAY_2':
                    $items[] = 'Paper tray '.substr($key, 5, 1).' is '.$value;
                    break;
                case 'INK_BLACK':
                    $perc = $value;
                    $items[] .= "<span title=\"black ink\"><b>Black</b> ink is at <b>$perc</b>:<div class=\"prog\"><div class=\"prog_ink_black\" style=\"width: $perc;\"></div></span>";
                    break;
                }
            }
        }
        $items[] = 'Last updated: '.std_date($filemtime, $now, true);
    }
} elseif (substr($id, 0, 4) == 'cam_') {
    $cam = substr($id, 4);
    $header = "Camera $cam";
    $file = "/var/www/html/htdocs/webcam/$cam.jpg";
    if (file_exists($file)) {
        $filemtime = filemtime($file);
    } else {
        $filemtime = 0;
    }
    $items[] = "<img src=\"/webcam/$cam.jpg\" width=\"352\" height=\"240\" alt=\"$cam webcam view of this room\" title=\"$cam\" />";
    $items[] = 'Last updated: '.std_date($filemtime, $now, true);
} else {
    do_die();
}
echo "<h4>$header</h4>";
echo '<ul>';
foreach ($items as $item) {
    echo "<li>$item</li>";
}
echo '</ul>';

?>

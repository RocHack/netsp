<?php

error_reporting(E_ALL);
ini_set('display_errors', '1');

function do_die() {
    header('Location: csug-comps.html');
    exit;
}

function parse_session($tty, $from, $login_date, $login_time) {
    $result = '';
    if (substr($tty, 0, 1) == ':' && $from == '') {
        $tty = substr($tty, 1);
        $result = "<b>login :$tty</b>";
    } elseif (substr($tty, 0, 3) == 'tty' && $from == '') {
        $tty = substr($tty, 3);
        $result = "<b>ctrl-alt-$tty</b>";
    } elseif (substr($tty, 0, 4) == 'pts/') {
        $tty = substr($tty, 4);
        $matches = array();
        $sfrom = $from;
        if (preg_match(',^:pts/(\d+):S.(\d+)$,', $from, &$matches)) {
            $sfrom = "<b>screen $matches[2]</b> from <b>pts/$matches[1]</b>";
        } elseif (preg_match(',^:(\d+)$,', $from, &$matches)) {
            $sfrom = "<b>terminal</b> from <b>login :$matches[1]</b>";
        } elseif (preg_match(',^localhost:(\d+)\.(\d+)$,', $from, &$matches)) {
            $sfrom = "<b>x-forwarded terminal</b> from <b>:$matches[1].$matches[2]</b>";
        } else {
            if (preg_match(',^(\S+)\.csug\.rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>$matches[1]</b>.csug.rochester.edu";
            } elseif (preg_match(',^(\d+)\.cs\.rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>$matches[1].cs.rochester.edu";
            } elseif (preg_match(',.*rochester\.edu$,', $from, &$matches)) {
                $sfrom = "<b>UR</b>";
            } elseif (preg_match(',^10\.\d+\.\d+\.\d+$,', $from, &$matches)) {
                $sfrom = "<b>UR_Connected</b>";
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
    return htmlspecialchars($in, ENT_NOQUOTES);
}

function pl($num) {
    return $num == 1 ? '' : 's';
}

function std_date($uts, $uts_now) {
    $m = ($uts_now - $uts) / 60;
    $h = $m / 60;
    $d = $h / 24;
    $m = $m % 60;
    $h = $h % 24;
    $d = floor($d);
    if ($m < 0) $m = 0;
    $t = "$m minute".pl($m);
    if ($h > 0) $t = "$h hour".pl($h).", $t";
    if ($d > 0) $t = "$d day".pl($d).", $t";
    return date('g:ia D, M j, Y ', $uts) . " ($t ago)";
}

$id = isset($_GET['id']) ? html_san($_GET['id']) : do_die();

$now = time();
$items = array();
if (substr($id, 0, 4) == 'box_') {
    $box = substr($id, 4);
    $file = "data/$box";
    if (file_exists($file)) {
        $filemtime = filemtime($file);
        $data = file_get_contents($file);
        $lines = explode("\n", $data);
        $info = explode(":", $lines[0]);
        $uptime = $filemtime - $info[2] * 60
                             - $info[1] * 60 * 60
                             - $info[0] * 60 * 60 * 24;
        $unqu = 0;
        $logu = 0;
        $ttyu = 0;
        $udata = array();
        for ($i = 1; $i < count($lines); $i++) {
            if (strlen($lines[$i]) > 0 && substr($lines[$i], 0, 1) != '.') {
                $fields = explode(' ', $lines[$i]);
                $tty = $fields[1];
                if (substr($tty, 0, 1) == ':') {
                    $logu++;
                } elseif (substr($tty, 0, 3) == 'tty') {
                    $ttyu++;
                }
          
                if (array_key_exists($fields[0], $udata)) {
                    $udata[$fields[0]][] = $fields;
                } else {
                    $udata[$fields[0]] = array($fields);
                    $unqu++;
                }
            }
        }
        $ulist = '';
        foreach ($udata as $uname => $sess_arr) {
            if ($ulist == '') $ulist = '<ul>';
            $uinfo = '<br />';
            foreach ($sess_arr as $idx => $sess) {
                $uinfo .= parse_session($sess[1], $sess[4], $sess[2], $sess[3]);
                if ($idx < count($sess_arr) - 1) {
                    $uinfo .= '<br />';
                }
            }
            $ulist .= "<li><a href=\"http://csug.rochester.edu/u/$uname/\" target=\"_blank\">$uname</a>$uinfo</li>";
        }
        if ($ulist != '') $ulist .= '</ul>';
        if ($now - $filemtime > 3600) {
            $items[] = '<span class="offline">This computer may be offline</span>';
        } else {
            $items[] = '<span class="online">This computer is on</span>';
        }
        $items[] = "Online users: $info[3] (all sessions), $unqu (unique), $logu (in lab), $ttyu (on ctrl-alt-#)$ulist";
        $items[] = 'Up since: '.std_date($uptime, $now);
        $items[] = 'Last pinged: '.std_date($filemtime, $now);
    } else {
        $items[] = '<span class="offline">No data</span>';
    }
    $header = "Computer Info for $box";
} elseif (substr($id, 0, 4) == 'prn_') {
    $prn = substr($id, 4);
    $curl = curl_init("http://$prn.csug.rochester.edu/");
    curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
    $body = curl_exec($curl);
    curl_close($curl);
    $header = "Printer Info for $prn";
    $items[] = $body;
} elseif (substr($id, 0, 4) == 'cam_') {
    $cam = substr($id, 4);
    $header = "Camera $cam";
    $items[] = "<img src=\"/webcam/$cam.jpg\" width=\"352\" height=\"240\" alt=\"$cam webcam view of this room\" title=\"$cam\" />";
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

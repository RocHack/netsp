(function () {
    var domain = '';
    var ip = '';
    var hosts = [];

    function getHostByName(name) {
        for (var i in hosts) {
            if (hosts[i].name == name) {
                return hosts[i];
            }
        }
        return null;
    }

    function mkIP(ipSubNetStr, ipHost) {
        var ipSubNet = ipSubNetStr.split('/');
        var ipSubNetMaskLen = Number(ipSubNet[1]);
        var ipSubNetMask = (-1) << (32 - ipSubNetMaskLen);
        var ip32 = ipSubNet[0]
        .split('.') // split into octets
        .map(function(el,i){
            return Number(el) * Math.pow(2, 24 - (8 * i)); // make each octet summable
        }).reduce(function(prev,curr){
            return prev+curr; // sum elements
        });
        var ip32Result = (ip32 & ipSubNetMask) |
            (ipHost & ((1 << (32 - ipSubNetMaskLen)) - 1));
        return ((ip32Result >>> 24) & 0xff).toString() + '.' +
               ((ip32Result >> 16) & 0xff).toString() + '.' +
               ((ip32Result >> 8)  & 0xff).toString() + '.' +
               ( ip32Result        & 0xff).toString();
    }

    // AJAX load/JSON parse error handler
    function fatalError(emsg, page) {
        $('a#logoLink').after($('<div class="content">'+
            '<h3>There was an error loading or parsing "'+page+'":</h3>'+
            '<h1 style="color:red">'+emsg+'</h1></div>'));
    }

    // calls fn('JSON "objDisplayName" has no element "el", which is required.')
    // returns true if all elements exist, false otherwise
    function requireJSONElements(obj, els, objDisplayName, url) {
        return !( els.map(function(el) {
            if (el in obj) {
                return true;
            } else {
                fatalError('JSON object "' + objDisplayName + '" has no property "' + el +
                   '" which is required to run this page.', url);
                return false;
            }
        }).indexOf(false) >= 0 );
    }

    function copyJSONElements(src, dst, els) {
        els.map(function(el) {
            if (el in src) {
                dst[el] = src[el];
            }
        });
    }

    // parse the STATIC layout file at csugnet/static-setup.json
    // generate the page body
    function parseData(data) {
        if (!requireJSONElements(
            data, ['name','displayName','domain','ip','categories','types','hosts'],
            'data', 'static-setup.json')) {
            return false;
        }

        var header = $('<div class="content" style="display:none">' +
             '<p class="tools"><span id="refresh" title="refresh">&#8635;</span></p>' +
             '<h3>Network Status Page <small>for the</small></h3>'+
             '<h1>'+data.displayName+'</h1>'+
             '<h3><small>at</small> '+data.domain+' ('+data.ip+')</h3>');

        domain = data.domain;
        ip = data.ip;

        var layouts = [];
        var order = [];

        for (var i in data.categories) {
            var category = data.categories[i];
            
            if (!requireJSONElements(
                category, ['name','displayName','room','position'],
                'data.categories['+i+']', 'static-setup.json')) {
                return false;
            }

            var grid = {};
            var maxRow = -1;
            var maxCol = -1;
            var rawLayout = '<div class="content" style="display:none"><h2>' +
                category.displayName + '</h2><h3>' + category.room + '</h3>' + 
                '<div class="layout_container">';
            for (var j in data.hosts) {
                var host = data.hosts[j];
            
                if (!requireJSONElements(
                    host, ['name','category','type','position','ip'],
                    'data.hosts['+j+']', 'static-setup.json')) {
                    return false;
                }

                if (host.category == category.name) {
                    host.category = category;
                    for (var k in data.types) {
                        var type = data.types[k];

                        if (!requireJSONElements(
                            type, ['name','displayName'],
                            'data.types['+k+']', 'static-setup.json')) {
                            return false;
                        }

                        if (host.type == type.name) {
                            host.type = type;
                        }
                    }
                    grid[String(host.position)] = host;
                    if (maxRow <= host.position[0]) {
                        maxRow = host.position[0] + 1;
                    }
                    if (maxCol <= host.position[1]) {
                        maxCol = host.position[1] + 1;
                    }
                    host.fullName = domain.replace('*', host.name);
                    host.fullIP = mkIP(ip, host.ip);
                    host.state = 'Loading';
                    host.color = '#aa0';
                    host.ready = false;
                    hosts.push(host);
                }
            }
            for (var r = 0; r < maxRow; r++) {
                for (var c = 0; c < maxCol; c++) {
                    if (String([r,c]) in grid) {
                        var host = grid[String([r,c])];
                        rawLayout += '<div class="layout '+
                            host.type.layoutName+'" id="'+
                            'host_'+host.name+'"><p data-color="yellow" style="color:#aa0">' +
                            host.name +
                            (('alias' in host) ? '<br/><small>' + host.alias.toString() +
                             '</small>' : '') + '<br/><small id="status_' + 
                            host.name+'">Wait</small></p></div>';
                    } else {
                        rawLayout += '<div class="layout spc"></div>';
                    }
                }
                rawLayout += '<br/>';
            }
            rawLayout += '</div></div>';
            layouts[i] = $(rawLayout);
            layouts[i].sortPosition = category.position;
        }
        layouts.sort(function (a,b) {
            return a.sortPosition - b.sortPosition;
        });

        $('a#logoLink').after(header);
        header.show();
        var prev = header;
        layouts.map(function (layout) {
            prev.after(layout);
            layout.show();
            prev = layout;
        });
        return true;
    }

    // parse the DYNAMIC global status data at csugnet/data.json
    // re-done every minute
    function parseStatus(data) {
        if (!requireJSONElements(
            data, ['hosts'],
            'data', 'data.json')) {
            return false;
        }
        
        for (var i in data.hosts) {
            var host = data.hosts[i];
            
            if (!requireJSONElements(
                host, ['name','state'],
                'data.hosts['+i+']','data.json')) {
                return false;
            }
            

            var hostsObj = getHostByName(host.name);
            if (hostsObj == null) {
                hosts.push(host);
            } else {
                copyJSONElements(host, hostsObj,
                    ['state','color','lastChange','lastCheck','os','cpu','mem',
                     'users','disks','prText','prModel','inks','trays']);
                hostsObj.ready = true;
            }

            host.color = (host.state == 'Up' ? 'green' :
                          (host.state == 'Down' ? 'red' : '#aa0'));
            $('#status_'+host.name).text(host.state);
            var ctx = $('#host_'+host.name+' p');
            if ('icon' in host) {
                //.html(img(host.icon + '.png', host.icon, 12, 12) + ' ' + host.name);
            } else {
                //.text(host.name);
            }
            var colorChanged = (ctx.attr('data-color') != host.color);
            ctx.attr('data-color',host.color);
            if (colorChanged) {
                ctx.animate({'opacity':.5},500,'swing', function () {
                    $(this).css({'color':$(this).attr('data-color')});
                    $(this).animate({'opacity':1},500,'swing');
                });
            }
        }

        return true;
    }

    function dt(dateObj, showSecs) {
        var now = new Date();
        //console.log('dt:'+dateObj + '\nnow:'+now);
        var t = 'am';
        if (dateObj.getHours() > 11) {
            t = 'pm';
        }
        var h = dateObj.getHours() % 12;
        if (h == 0) {
            h = 12;
        }
        var m = dateObj.getMinutes();
        var ms = m.toString();
        if (ms.length == 1) {
            ms = '0' + ms;
        }
        var s = dateObj.getSeconds();
        var ss = s.toString();
        if (ss.length == 1) {
            ss = '0' + ss;
        }
        var d = dateObj.getDate();
        var ds = d.toString();
        var dord = d % 10;
        if (dord > 3 || (d >= 10 && d < 20)) {
            dord = 0;
        }
        ds += (['th', 'st', 'nd', 'rd'])[dord];
        var w = dateObj.getDay();
        var ws = (['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'])[w % 7];
        var n = dateObj.getMonth();
        var ns = ' ' + (['January','February','March','April','May','June',
                         'July','August','September','October','November','December'])[n % 12];
        var y = dateObj.getFullYear();
        var ys = ' ' + y.toString();
        if (y == now.getFullYear()) {
            ys = '';
        }
        if (n == now.getMonth() && y == now.getFullYear()) {
            ns = '';
        }
        if (d == now.getDate() && n == now.getMonth() && y == now.getFullYear()) {
            ds = b('today');
            ws = ns = ys = '';
        } else {
            ws = 'on ' + ws + ' the ';
            ns = (ns.length ? ' of' : '') + ns + (ys.length ? ', ' : '');
        }
        var ago = '';
        var ago_s = Math.round((now.getTime() - dateObj.getTime()) / 1000);
        if (ago_s < 0) {
            ago = ' from now';
            ago_s = Math.abs(ago_s);
        } else if (ago_s == 0) {
            ago = 'now';
        } else {
            ago = ' ago';
        }
        var ago_m = Math.floor(ago_s / 60);
        var ago_s60 = ago_s % 60;
        var ago_h = Math.floor(ago_m / 60);
        var ago_m60 = ago_m % 60;
        var ago_d = Math.floor(ago_h / 24);
        var ago_h24 = ago_h % 24;
        var ago_y = Math.floor(ago_d / 365);
        var ago_d365 = ago_d % 365;
        if (ago_s != 0) {
            ago = (ago_y > 0 ? ago_y + ' year' + (ago_y == 1 ? '' : 's') + ', ' : '') +
                  (ago_d365 > 0 ? ago_d365 + ' day' + (ago_d365 == 1 ? '' : 's') + ', ' : '') +
                  (ago_h24 > 0 ? ago_h24 + ' hour' + (ago_h24 == 1 ? '' : 's') + ', ' : '') +
                  (ago_y + ago_d365 + ago_h24 > 0 && !showSecs ? 'and ' : '') +
                   ago_m60 + ' minute' + (ago_m60 == 1 ? '' : 's') +
                  (showSecs ? ', and ' + ago_s60 + ' second' + (ago_s60 == 1 ? '' : 's') : '') +
                  ago;
        }

        return b(h + ':' + ms + (showSecs ? ':' + ss : '') + t) + ' ' + ws + ds + ns + ys;
        // + ' (' + b(ago, /(\d+)/g) + ')';
    }

    function hertz(val, mag) {
        return magnitudes(val, mag, 'Hz', 1000);
    }

    function bytes(val, mag) {
        return magnitudes(val, mag, 'B', 1024);
    }

    function magnitudes(val, mag, suffix, power) {
        var mags = ['', 'k', 'M', 'G', 'T', 'P', 'E'];
        var magI = mags.indexOf(mag);
        while (val > power * 0.9) {
            val = val / power;
            magI++;
        }
        mag = mags[magI];
        return b(val.toFixed(2)) + ' ' + mag + suffix;
    }

    // bold a section of the given text for the tooltip, 
    function b(text, rx) {
        return (rx == null ? '<b>'+text+'</b>' : text.replace(rx, '<b>$1</b>'));
    }

    function img(src, alt, w, h) {
         return '<img width="' + w + '" height="' + h + '" src="' + src + '" ' +
                'alt="' + alt + '" />';
    }

    function dutf8(s) {
        return decodeURIComponent(escape(s));
    }

    function eutf8(s) {
        return unescape(encodeURIComponent(s));
    }

    function progressBar(color, percent, decPts) {
        return'<div class="prog"><div class="prog_' + color + '" ' +
            'style="width: ' + (percent * 100).toFixed(1) + '%;">' +
            b((percent * 100).toFixed(decPts) + ' %') +
            '</div></div>';
    }

    function doMatchSession(M, toMatch, p) {
        return M.map(function(obj) {
            if (obj.match.test(toMatch)) {
                return {
                    display: p != null ? p : toMatch.replace(obj.match, obj.display),
                    parentDisplay: toMatch.parentDisplay
                };
            } else {
                return null;
            }
        }).reduce(function(p,c) {
            return p == null ? c : p;
        });
    }

    function parseSession(tty, host) {
        var ttyTypeM = [
        { match: /tty(\d+)/, on: 'ctrl+alt+f$1' },
        { match: /pts\/(\d+)/, on: 'ssh', as: 'pts/$1' },
        { match: /:(\d+)\.(\d+)/, on: 'graphical login $1 (port $2)' },
        { match: /:(\d+)/, on: 'graphical login $1' },
        { match: /dtremote/, on: 'graphical login', noOverrideOn: true },
        { match: /(.*)/, on: 'unknown' }
        ];
        var displayObj = { order: ['on','as','from','via'] };
        ttyTypeM.map(function (obj) {
            if (obj.match.test(tty)) {
                if (!('on' in displayObj)) {
                    displayObj.on = tty.replace(obj.match, obj.on);
                    if ('as' in obj) {
                        displayObj.as = tty.replace(obj.match, obj.as);
                    }
                }
            }
        });

        var hostTypeM = [
        { match: /\*/, from: '' },
        { match: /^([^:]*):tty(\d+):S\.(\d+)$/, on: 'screen $3', from: 'ctrl+alt+f$2', via: '$1' },
        { match: /^([^:]*):(\S+):S\.(\d+)$/, on: 'screen $3', from: '$2', via: '$1' },
        { match: /^([^:]*):(\d+)\.(\d+)$/, from: 'graphical server $2 (port $3)', via: '$1',
            on: 'terminal', as: '' },
        { match: /^([^:]*):(\d+)$/, from: 'graphical server $2', via: '$1',
            on: 'terminal', as: '' },
        { match: /(.*)/, from: 'host $1' }
        ];
        hostTypeM.map(function (obj) {
            if (obj.match.test(host)) {
                if (!('from' in displayObj)) {
                    (['from','via','on','as']).map(function (fieldName) {
                        if (fieldName in obj && !('noOverrideOn' in displayObj)) {
                            displayObj[fieldName] = host.replace(obj.match, obj[fieldName]);
                        }
                    });
                }
            }
        });
        if (/^[^:]+:\S+(?::(?:\d+|S)(?:\.\d+)?)?$/.test(host)) {
            displayObj.on = 'remote '+displayObj.on;
        }

        return displayObj.order.map(function (fieldName) {
            if (fieldName in displayObj && displayObj[fieldName] != '') {
                return fieldName + ' ' + b(displayObj[fieldName]);
            } else {
                return '';
            }
        }).join(' ');
    }

    // given a host object, return the HTML to insert
    function parseHost(host) {
        if (!requireJSONElements(
            host, ['name', 'category', 'type', 'ip', 'position', 'state'],
            'host', 'data.json')) {
            return null;
        }

        host.color = (host.state == 'Up' ? 'green' :
                      (host.state == 'Down' ? 'red' : '#aa0'));

        var lines = [];
        //console.log(host);
        lines.push('Host: ' + ('webServer' in host && host.webServer ?
                '<a href="http://' + host.fullName + '/">' +
                b(host.fullName, /^([^.]+)/) + '</a>' :
                b(host.fullName, /^([^.]+)/)) + ' (' + b(host.fullIP, /([\d]+)$/) +
                ')' + ('externalAccess' in host && host.externalAccess ?
                ' (accessible outside the network)' : ''));
        if ('alias' in host) {
            var es = host.alias.length == 1 ? '' : 'es';
            var aliases = '';
            host.alias.map(function(a){
                if (aliases.length > 0) {
                    aliases += ', ';
                }
                aliases += b(host.fullName.replace(host.name, a).replace('..', ''), /^([^.]+)/)
            });
            lines.push('Alias'+es+': ' + aliases);
        }

        var since = '';
        if ('lastChange' in host) {
            since = ' since ' + dt(new Date(host.lastChange*1000), false);
        }

        lines.push('State: <b style="color:' + host.color + '">This '+
            host.type.displayName.toLowerCase() + ' is ' +
            host.state.toLowerCase() + '</b>' + since);

        if ('lastCheck' in host) {
            lines.push('Last checked: ' + dt(new Date(host.lastCheck*1000), true));
        }

        if ('os' in host) {
            lines.push('Operating system: ' +
                     img('csugnet/img/' + host.os.class + '.png', host.os.class, 12, 12) + ' ' +
                     b(dutf8(host.os.release)));
        }

        if ('cpu' in host && host.cpu.modelClean && host.cpu.speed && host.cpu.threads) {
            lines.push('CPU: ' +
                    b(dutf8(host.cpu.modelClean
                        .replace(/\(R\)/g, '&reg;')
                        .replace(/\(TM\)/g, '&trade;'))) +
                    ' (' + hertz(host.cpu.speed, 'M') +
                    ' on ' + b(host.cpu.threads) + ' logical core' +
                    (host.cpu.threads == 1 ? '' : 's') + ')');
        }

        if ('mem' in host && host.mem.total) {
            lines.push('Memory: ' + bytes(host.mem.total, 'k'));
        }

        if ('disks' in host && host.disks && host.disks.length > 0) {
            lines.push('Disks: ' + host.disks.length + ' mounted<ul>' +
                host.disks.map(function(disk) {
                    return '<li>' + b(disk.path) + ' is mounted with ' +
                        bytes(disk.used, 'k') + ' in use of ' + bytes(disk.total, 'k') +
                        '<br/>' + progressBar(disk.used / disk.total > .8 ? 'red' : 'blue', disk.used / disk.total, 2) + '</li>';
                }).join('') + '</ul>');
        }

        if ('prModel' in host) {
            lines.push('Printer Model: ' + 
                     img('csugnet/img/hp.png', 'hp', 12, 12) + ' ' +
                     b(dutf8(host.prModel)));
        }

        if ('prText' in host) {
            lines.push('Status: <pre>' + b(dutf8(host.prText.split('\n').join('<br/>'))) + '</pre>');
        }

        if ('inks' in host) {
            lines.push('Ink cartridges: ' + host.inks.length + ' installed<ul>' +
                host.inks.map(function(ink) {
                    return '<li>' + b(ink.color) + ' cartridge<br/>' +
                    progressBar(ink.color.toLowerCase(), ink.amount / 100, 0) + '</li>';
                }).join('') + '</ul>');
        }

        if ('trays' in host) {
            lines.push('Paper trays: ' + host.trays.length + ' installed<ul>' +
                host.trays.map(function(tray) {
                    return '<li>Tray ' + b(tray.index) + ' is ' + b(tray.state) + '</li>';
                }).join('') + '</ul>');
        }

        if ('users' in host) {
            var sess = '';
            var sessList = [];
            var lastSess = null;
            host.users.sort(function(a,b) {
                return a.netid.localeCompare(b.netid);
            }).map(function(user) {
                var currSess = {
                    name: user.netid,
                    sessions: [],
                    header: 
                    (user.folderExists ? '<a style="font-weight:bold" href="/u/' +
                     user.netid + '/">' + dutf8(user.name) + '</a>' :
                     b(dutf8(user.name)) + ' (no user directory)')
                };
                if (lastSess != null) {
                    if (lastSess.name == user.netid) {
                        currSess = lastSess;
                    } else {
                        sessList.push(lastSess);
                    }
                }
                currSess.sessions.push(
                    parseSession(user.tty, user.host) +
                    ' since ' + dt(new Date(user.loginTime*1000)));

                lastSess = currSess;
            });
            if (lastSess != null) {
                sessList.push(lastSess);
            }
            if (sessList.length > 0) {
                sess = '<ul>' + sessList.map(function (sessObj) {
                    return '<li>' + sessObj.header + '<ul>' + sessObj.sessions.map(function (userObj) {
                        return '<li>' + userObj + '</li>';
                    }).join('') + '</ul></li>';
                }).join('') + '</ul>';
            }
            lines.push('Users: ' +
                    sessList.length + ' online ' +
                    '(' + host.users.length + ' session' +
                    (host.users.length == 1 ? '' : 's') + ')' +
                    sess);
            lastSess = null;
        }

        if ('webLocation' in host) {
            lines.push('Most recent snapshot:<br/>' +
                    img(host.webLocation, host.fullName + ' snapshot', 352, 240));
        }

        var html = '<h2>Info for ' + host.type.displayName + ' ' + host.name + '</h2><ul>';
        for (var i in lines) {
            html += '<li>' + lines[i] + '</li>';
        }
        html += '</ul>';
        return html;
    }

    $(document).ajaxError(function (e, jqXHR, set, ex) {
        if (set.url == 'csugnet/static-setup.json' ||
            set.url == 'csugnet/data.json') {
            fatalError('HTTP error: '+ex, set.url.substr(8));
        }
    });

    $(document).ready(function () {
        var globalRefreshTimeout = null;

        // init: get static-setup.json
        $.ajax({
            cache: false,
            dataType: 'json',
            url: 'csugnet/static-setup.json'
        }).done(function(data, textStatus, jqXHR) {
             // on success, parse it
             if (parseData(data)) {
                 // every minute: get data.json
                 globalRefreshTimeout = setInterval(function(){
                     refresh();
                 }, 60000);
                 refresh();
                 // bind tooltip events
                 bindTooltipEvents();
             }
        });
    });

    function refresh() {
         $.ajax({
             cache: false,
             dataType: 'json',
             url: 'csugnet/data.json'
         }).done(function(data, textStatus, jqXHR) {
             if (!parseStatus(data)) {
                 clearTimeout(globalRefreshTimeout);
             }
         });
    }

    function bindTooltipEvents() {
        var hideTimeout = null;
        var current = null;
        // on mouseover or click: get data/<host>.json
        $('.comp, .printer, .camera').on('mouseover click', function () {
            if (hideTimeout) {
                clearTimeout(hideTimeout);
                hideTimeout = null;
            }
            current = $(this);
            var off = current.offset();
            var hostName = current.attr('id').substr(5);
            var host = getHostByName(hostName);
            if (!host.ready) {
                return;
            }
            var parsed = null;
            if (host == null) {
                parsed = '<h3 style="color:red">Host "' + hostName + '" does not exist.</h3>';
            } else {
                parsed = parseHost(host);
                if (parsed == null) {
                    parsed = '<h3 style="color:red">There was an error parsing the host data.</h3>';
                }
            }
            //$('#infobox').offset({ top: off.top - h - 20, left: off.left });
            $('#infobox > p.remote').html(parsed);
            $('#infobox').fadeIn();
            var w = $('#infobox').outerWidth();
            var h = $('#infobox').outerHeight();
            var pushRight = 0;
            if (w + off.left > current.parent().width() + current.parent().offset().left) {
                pushRight = off.left + w - current.parent().offset().left - current.parent().width();
            }
            $('#infobox').offset({ top: off.top + current.height() + 40, left: off.left - pushRight });
            $('#infobox_arrow').show().offset({ top: $('#infobox').offset().top - $('#infobox_arrow').outerHeight(),
                left: off.left + current.width() / 3});
            //} else { else: the ajax is currently working
        });
        $('#infobox, #infobox_arrow').on('mouseover', function () {
            if (hideTimeout) {
                clearTimeout(hideTimeout);
                hideTimeout = null;
            }
        });
        $('.comp, .printer, .camera, #infobox').on('mouseout', function () {
            if (hideTimeout) {
                clearTimeout(hideTimeout);
                hideTimeout = null;
            }
            hideTimeout = setTimeout(function () {
                current = null;
                $('#infobox').fadeOut();
                $('#infobox_arrow').hide();
            },5000);
        });
        $('#infobox #close').on('click', function () {
            current = null;
            if (hideTimeout) {
                clearTimeout(hideTimeout);
                hideTimeout = null;
            }
            $('#infobox').fadeOut();
            $('#infobox_arrow').hide();
        });
        $('#refresh').on('click', function () {
            refresh();
        });
    }
})();


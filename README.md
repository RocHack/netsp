CSUG Network Status Page Scripts
================================

This is the magic behind [csugnet.html][1] in [csug-home][2], currently live [here][3].

1. The main script, ``infobox.pl``, runs on every computer on the network.
2. The current status is stored by this script in a world readable file, called
   the Data file, located at ``data.json`` in this directory. It is .gitignored
   because it will update frequently as each script grabs a lock and rewrites
   it's host file.
3. When you visit csugnet.html, the current status interpreted from
   ``static-setup.json`` and ``data.json``.
   * First, the page is constructed with ``static-setup.json`` which holds
     names, addresses, and layout positions for all networked things to be
     shown.
   * Second, the statuses are retrieved once a minute (or more often by user
     request) from ``data.json`` and the tooltips are created by JavaScript.

Components:
* ``init_infobox.sh``: The current hack to initialize the Network Status Page
  (NSP) on all computers.  I have a plan for this to use the
 ``static-setup.json`` data to initialize and tell ``data.json`` about
  not-responding devices.
* ``infobox.pl``: The polling script. Tries to be idle as often as possible,
  updating ``data.json`` once every 60 seconds with the current device status.
* ``data.json``: A dynamically-modified storage space for the current network
  status.
* ``static-setup.json``: The network configuration, just containing the hosts
  on the network, their addresses, and how to lay out a page to display them.
* ``../csugnet.html``: The page that renders this NSP by including ``nsp.js``,
  ``style.css``, a valid ``static-setup.json``, a set of running devices with
  at least one computer running ``infobox.pl``, one instance for each device,
  and a valid tag with the id ``nsp`` to replace.
* ``style.css``: Stylesheet for elements of the NSP.
* ``nsp.js``: The JavaScript to run the NSP.
* ``index.php``: A short script that moves you up one level to the NSP then
  exits.

[1]: https://github.com/nmbook/csug-home/blob/master/csugnet.html
[2]: https://github.com/nmbook/csug-home
[3]: https://csug.rochester.edu/u/nbook/csugnet.html


Network Status Page Scripts for UR CSUG and CS Networks
=======================================================

This is the magic behind the Network Status Page (NetSP), masterminded by Nate Book
and modified slightly by Hassler Thurston, currently live [here][3].

1. The main script, `infobox.pl`, runs on every computer on the network.
2. The current status is stored by this script in a world readable file, called
   the Data file, located at `data.json` in this directory. It is .gitignored
   because it will update frequently as each script modifies it.
3. When you visit `netsp-csug.html`, the current status interpreted from
   `static-setup.json` and `data.json`.
   * First, the page is constructed with `static-setup.json` which holds
     meta-data, including layout positions, for all devices to be shown.
   * Second, the statuses are retrieved once a minute (or more often by user
     request) from `data.json` and the tooltips are created by JavaScript.

Components:
* `infobox.pl`: The polling script. Tries to be idle as often as possible,
  updating `data.json` once every 60 seconds with the current device status.
  There is a "master" script running and checking for other computers' scripts'
  downtime (when they haven't updated `data.json` recently enough). If so, the
  offender is marked as "Down" and the script is attempted to be restarted.
  The master script checks the non-computer devices, such as drives, cameras,
  and printers. The rest are called "slaves" and only check themselves. The
  system is designed to have exactly one script running on each system.
* `data.json`: A dynamically-modified JSON file for the current status.
* `static-setup.json`: The network configuration, just containing the hosts on
  the network, their addresses, and how to lay out a page to display them.
* `../netsp-csug.html`: The page that renders this NetSP by including
  `netsp.js`, `style.css`, a valid `static-setup.json`, a set of running
  devices with at least one computer running `infobox.pl`, one instance for
  each device, and a valid tag with the id `div#netsp-link` to replace.
* `style.css`: Stylesheet for elements of the NetSP.
* `netsp.js`: The JavaScript to run the NetSP.
* `index.php`: A short script that moves you up one level to the NetSP page.

Useful links:
* [netsp-csug.html][1] page, in Nate Book's CSUG-home repository
* GitHub home of Nate's [CSUG-home][2] repository 

[1]: https://github.com/nmbook/csug-home/blob/master/netsp-csug.html
[2]: https://github.com/nmbook/csug-home
[3]: https://csug.rochester.edu/u/jthurst3/csug-home/netsp-csug.html


CSUG Network Status Page Scripts
================================

This is the magic behind [csugnet.html][1] in [csug-home][2], currently live [here][3].

1. The main script, infobox.pl, runs on every computer on the network.
2. The current status is stored by this script in a world readable file, called
   the Data file, relative to the script (data/``hostname``).
3. When you visit csugnet.html, the current status is read from the Data file
   with ajax. Right now it uses an intermediary parser, infobox.php, that
   parses the raw Data into HTML. I plan to remove this step and store the Data
   file as JSON that will be parsed by csugnet.html (probably by a JavaScript
   moved here).

[1]: https://github.com/nmbook/csug-home/blob/master/csugnet.html
[2]: https://github.com/nmbook/csug-home
[3]: https://csug.rochester.edu/u/nbook/csugnet.html


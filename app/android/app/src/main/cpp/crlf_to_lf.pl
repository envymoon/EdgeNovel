# perl -pi crlf_to_lf.pl <files>: CRLF line ends to LF. A script, not -e:
# FetchContent reads its commands twice, and a \r there turns into a real one.
s/\r$//;

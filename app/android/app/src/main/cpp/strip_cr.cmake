# cmake -DFILE=<path> -P strip_cr.cmake: CRLF line ends to LF, so a patch
# written with LF applies (stable-diffusion.cpp keeps src/convert.cpp in CRLF).
file(READ "${FILE}" text)
string(REPLACE "\r\n" "\n" text "${text}")
file(WRITE "${FILE}" "${text}")

/*
 * test to build and run so that we know if we have getprotobyname_r
 * and getprotobynumber_r.
 *
 * Note that this checks for a conventional getprotoby*_r as on Linux,
 * SunOS-derived OSes have them, but with different signatures, and fail this
 * test so as to avoid confusion.
 */

#include <netdb.h>

#define BUFSIZE 1024

int main ()
{
    struct protoent result_buf;
    struct protoent *result;
    char buf[BUFSIZE];
    getprotobyname_r("", &result_buf, buf, BUFSIZE, &result);
    getprotobynumber_r("", &result_buf, buf, BUFSIZE, &result);
    return 104;
}

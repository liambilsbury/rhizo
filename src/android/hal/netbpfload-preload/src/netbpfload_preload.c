#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>

static const char NETBPFLOAD[] = "/apex/com.android.tethering/bin/netbpfload";
static const char SHIM[] = "/system_ext/lib64/rhizo_bpf_preload.so";

// exec netbpfload with LD_PRELOAD set
int main(int argc, char** argv) {
    setenv("LD_PRELOAD", SHIM, 1);
    char* newargv[argc + 1];
    newargv[0] = (char*)NETBPFLOAD;
    for (int i = 1; i < argc; i++) newargv[i] = argv[i];
    newargv[argc] = NULL;
    execv(NETBPFLOAD, newargv);
    fprintf(stderr, "rhizo_netbpfload_preload: execv(%s): %s\n", NETBPFLOAD, strerror(errno));
    return 127;
}

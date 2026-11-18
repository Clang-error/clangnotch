// ClangNotch's energy mode helper: a launchd daemon (SMAppService, installed only when the user
// asks for it from the Battery tab) that runs one fixed `pmset` command as root, so changing the
// Mac's energy mode doesn't ask for the password every time (user, 2026-11-18).
//
// What it accepts is kept as small as it can be:
// - only a caller signed by this team with the app's identifier (the peer code signing
//   requirement, checked by XPC against the running process, so a process whose code was
//   changed after launch fails it; TEAM_ID comes from the build's DEVELOPMENT_TEAM). A release
//   build also refuses a caller that allows a debugger (get-task-allow, which development builds
//   carry): attaching to it would be a way to send messages as ClangNotch. The app is built with
//   the hardened runtime and no library validation or DYLD exceptions, so nothing can be loaded
//   into it either;
// - only a mode number 0, 1 or 2 and two flags for how this Mac's pmset names it. Every word it
//   runs is a fixed string here; nothing from the message reaches the command line. Someone who
//   did get in as ClangNotch could change the energy mode and nothing else.
// It exits 20 s after the last message; launchd starts it again on the next one.
#include <dispatch/dispatch.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <xpc/xpc.h>

#ifndef TEAM_ID
#error TEAM_ID must be defined
#endif

#ifndef LABEL  // overridden only to run an attack test as a user agent
#define LABEL "com.clangerror.ClangNotch.EnergyHelper"
#endif
#define DEVELOPER_REQUIREMENT "anchor apple generic and identifier \"com.clangerror.ClangNotch\" and certificate leaf[subject.OU] = \"" TEAM_ID "\""
#ifdef RELEASE_PEER
#define REQUIREMENT DEVELOPER_REQUIREMENT " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
#else
#define REQUIREMENT DEVELOPER_REQUIREMENT
#endif

static dispatch_source_t idle;

static void keep_alive(void) {
    dispatch_source_set_timer(idle, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
}

static bool run(const char *const argv[]) {
    char *const env[] = { NULL };
    pid_t pid;
    if (posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, env) != 0) return false;
    int status;
    while (waitpid(pid, &status, 0) < 0) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static bool set_mode(int64_t mode, bool three_way, bool high_power) {
    static const char *const digits[] = { "0", "1", "2" };
    if (mode < 0 || mode > 2) return false;
    if (three_way) {
        const char *const argv[] = { "/usr/bin/pmset", "-a", "powermode", digits[mode], NULL };
        return run(argv);
    }
    const char *low = mode == 1 ? "1" : "0";
    if (high_power) {
        const char *const argv[] = { "/usr/bin/pmset", "-a", "lowpowermode", low, "highpowermode", mode == 2 ? "1" : "0", NULL };
        return run(argv);
    }
    if (mode == 2) return false;
    const char *const argv[] = { "/usr/bin/pmset", "-a", "lowpowermode", low, NULL };
    return run(argv);
}

static void handle(xpc_connection_t peer, xpc_object_t message) {
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;  // errors, a rejected signature too
    keep_alive();
    bool ok = set_mode(xpc_dictionary_get_int64(message, "mode"),
                       xpc_dictionary_get_bool(message, "threeWay"),
                       xpc_dictionary_get_bool(message, "highPower"));
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply) return;
    xpc_dictionary_set_bool(reply, "ok", ok);
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

int main(void) {
    idle = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(idle, ^{ exit(0); });
    keep_alive();
    dispatch_resume(idle);

    xpc_connection_t listener = xpc_connection_create_mach_service(LABEL, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t connection = (xpc_connection_t)peer;
        if (xpc_connection_set_peer_code_signing_requirement(connection, REQUIREMENT) != 0) {
            xpc_connection_cancel(connection);
            return;
        }
        xpc_connection_set_event_handler(connection, ^(xpc_object_t message) { handle(connection, message); });
        xpc_connection_resume(connection);
    });
    xpc_connection_resume(listener);
    dispatch_main();
}

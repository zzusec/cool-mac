#include "CIPC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecBase.h>
#include <Security/SecCode.h>
#include <Security/SecStaticCode.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <os/log.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define CM_MANIFEST_MAX_BYTES (64u * 1024u)
#define CM_MAX_HASHES 128
#define CM_ERROR_MAX_BYTES 1024u
#define CM_MAX_PEERS 64u

/* A small bounded syntax check; the guardian still decodes the typed protocol. */
struct cm_json { const unsigned char *p, *end; };
static void cm_json_space(struct cm_json *j) {
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\r' || *j->p == '\n')) ++j->p;
}
static int cm_hex(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static bool cm_json_string(struct cm_json *j) {
    if (j->p == j->end || *j->p++ != '"') return false;
    while (j->p < j->end) {
        unsigned char c = *j->p++;
        if (c == '"') return true;
        if (c < 0x20) return false;
        if (c != '\\') continue;
        if (j->p == j->end) return false;
        c = *j->p++;
        if (c == 'u') {
            for (unsigned i = 0; i < 4; ++i)
                if (j->p == j->end || cm_hex(*j->p++) < 0) return false;
        } else if (!strchr("\"\\/bfnrt", c)) return false;
    }
    return false;
}
static bool cm_json_value(struct cm_json *j, unsigned depth) {
    cm_json_space(j);
    if (depth > 32 || j->p == j->end) return false;
    unsigned char c = *j->p;
    if (c == '"') return cm_json_string(j);
    if (c == '{' || c == '[') {
        ++j->p;
        cm_json_space(j);
        unsigned char close = c == '{' ? '}' : ']';
        if (j->p < j->end && *j->p == close) { ++j->p; return true; }
        for (;;) {
            if (c == '{') {
                if (!cm_json_string(j)) return false;
                cm_json_space(j);
                if (j->p == j->end || *j->p++ != ':') return false;
            }
            if (!cm_json_value(j, depth + 1)) return false;
            cm_json_space(j);
            if (j->p == j->end) return false;
            if (*j->p == close) { ++j->p; return true; }
            if (*j->p++ != ',') return false;
            cm_json_space(j);
        }
    }
    const char *literal = c == 't' ? "true" : c == 'f' ? "false" : c == 'n' ? "null" : NULL;
    if (literal) {
        size_t length = strlen(literal);
        if ((size_t)(j->end - j->p) < length || memcmp(j->p, literal, length)) return false;
        j->p += length;
        return true;
    }
    if (*j->p == '-') ++j->p;
    if (j->p == j->end) return false;
    if (*j->p == '0') ++j->p;
    else {
        if (*j->p < '1' || *j->p > '9') return false;
        while (j->p < j->end && *j->p >= '0' && *j->p <= '9') ++j->p;
    }
    if (j->p < j->end && *j->p == '.') {
        const unsigned char *start = ++j->p;
        while (j->p < j->end && *j->p >= '0' && *j->p <= '9') ++j->p;
        if (start == j->p) return false;
    }
    if (j->p < j->end && (*j->p == 'e' || *j->p == 'E')) {
        ++j->p;
        if (j->p < j->end && (*j->p == '+' || *j->p == '-')) ++j->p;
        const unsigned char *start = j->p;
        while (j->p < j->end && *j->p >= '0' && *j->p <= '9') ++j->p;
        if (start == j->p) return false;
    }
    return true;
}
static bool cm_valid_json(const void *bytes, size_t length, size_t maximum) {
    if (!bytes || !length || length > maximum || memchr(bytes, 0, length)) return false;
    CFStringRef utf8 = CFStringCreateWithBytes(NULL, bytes, (CFIndex)length, kCFStringEncodingUTF8, false);
    if (!utf8) return false;
    CFRelease(utf8);
    struct cm_json j = { bytes, (const unsigned char *)bytes + length };
    cm_json_space(&j);
    if (j.p == j.end || *j.p != '{' || !cm_json_value(&j, 0)) return false;
    cm_json_space(&j);
    return j.p == j.end;
}

struct cm_policy { uint32_t uid; CFMutableSetRef hashes; };
static void cm_policy_destroy(struct cm_policy *policy) {
    if (policy->hashes) CFRelease(policy->hashes);
    policy->hashes = NULL;
}
static int cm_policy_hashes(CFTypeRef value, CFMutableSetRef hashes) {
    if (!value || CFGetTypeID(value) != CFArrayGetTypeID()) return EINVAL;
    CFIndex count = CFArrayGetCount(value);
    if (count > CM_MAX_HASHES) return E2BIG;
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef item = CFArrayGetValueAtIndex(value, i);
        char hex[CM_CODE_HASH_CAPACITY];
        if (CFGetTypeID(item) != CFStringGetTypeID() || CFStringGetLength(item) != 40 ||
            !CFStringGetCString(item, hex, sizeof(hex), kCFStringEncodingASCII)) return EINVAL;
        unsigned char bytes[20];
        for (size_t k = 0; k < sizeof(bytes); ++k) {
            int high = cm_hex((unsigned char)hex[k * 2]), low = cm_hex((unsigned char)hex[k * 2 + 1]);
            if (high < 0 || low < 0) return EINVAL;
            bytes[k] = (unsigned char)((high << 4) | low);
        }
        CFDataRef data = CFDataCreate(NULL, bytes, sizeof(bytes));
        if (!data) return ENOMEM;
        CFSetAddValue(hashes, data);
        CFRelease(data);
    }
    return 0;
}
static int cm_policy_parse(CFDataRef data, struct cm_policy *policy) {
    CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    if (!plist) return EINVAL;
    int result = EINVAL;
    if (CFGetTypeID(plist) != CFDictionaryGetTypeID()) goto out;
    CFTypeRef uid = CFDictionaryGetValue(plist, CFSTR("authorizedUID"));
    int64_t number = -1;
    if (!uid || CFGetTypeID(uid) != CFNumberGetTypeID() || CFNumberIsFloatType(uid) ||
        !CFNumberGetValue(uid, kCFNumberSInt64Type, &number) || number < 0 || number >= UINT32_MAX) goto out;
    policy->uid = (uint32_t)number;
    policy->hashes = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
    if (!policy->hashes) { result = ENOMEM; goto out; }
    result = cm_policy_hashes(CFDictionaryGetValue(plist, CFSTR("clientCDHashes")), policy->hashes);
    if (!result) result = cm_policy_hashes(CFDictionaryGetValue(plist, CFSTR("cliCDHashes")), policy->hashes);
    if (!result && !CFSetGetCount(policy->hashes)) result = EINVAL;
out:
    CFRelease(plist);
    if (result) cm_policy_destroy(policy);
    return result;
}
static bool cm_manifest_stat_valid(const struct stat *s) {
    return S_ISREG(s->st_mode) && s->st_uid == 0 && s->st_gid == 0 &&
           !(s->st_mode & (S_IWGRP | S_IWOTH)) && s->st_size > 0 && s->st_size <= CM_MANIFEST_MAX_BYTES;
}
static int cm_policy_load(const char *path, struct cm_policy *policy) {
    if (!path || path[0] != '/') return EINVAL;
    struct stat before, opened, after;
    if (lstat(path, &before)) return errno;
    if (!cm_manifest_stat_valid(&before)) return EACCES;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return errno;
    int result = 0;
    unsigned char *bytes = NULL;
    if (fstat(fd, &opened)) { result = errno; goto out; }
    if (!cm_manifest_stat_valid(&opened) || opened.st_dev != before.st_dev || opened.st_ino != before.st_ino) {
        result = EACCES; goto out;
    }
    /* Mode bits alone do not exclude an ACL granting non-root write access. */
    acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (acl) {
        acl_entry_t entry;
        errno = 0;
        int entry_result = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry);
        int entry_errno = errno;
        acl_free(acl);
        /* Darwin returns 0 for an entry, -1/EINVAL for an empty valid ACL. */
        if (entry_result == 0 || entry_errno != EINVAL) { result = EACCES; goto out; }
    } else if (errno != ENOENT) {
        /* On an open descriptor, ENOENT means no extended ACL is present. */
        result = errno ? errno : EACCES;
        goto out;
    }
    bytes = malloc(CM_MANIFEST_MAX_BYTES + 1);
    if (!bytes) { result = ENOMEM; goto out; }
    size_t length = 0;
    for (;;) {
        ssize_t count = read(fd, bytes + length, CM_MANIFEST_MAX_BYTES + 1 - length);
        if (count < 0) { if (errno == EINTR) continue; result = errno; goto out; }
        if (!count) break;
        length += (size_t)count;
        if (length > CM_MANIFEST_MAX_BYTES) { result = EFBIG; goto out; }
    }
    if (fstat(fd, &after)) { result = errno; goto out; }
    if (!cm_manifest_stat_valid(&after) || after.st_size != (off_t)length ||
        opened.st_size != after.st_size || opened.st_uid != after.st_uid || opened.st_gid != after.st_gid ||
        opened.st_mode != after.st_mode || opened.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
        opened.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec || opened.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
        opened.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) { result = EACCES; goto out; }
    CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)length);
    if (!data) { result = ENOMEM; goto out; }
    result = cm_policy_parse(data, policy);
    CFRelease(data);
out:
    free(bytes);
    close(fd);
    return result;
}

struct cm_server;
struct cm_peer {
    xpc_connection_t connection;
    dispatch_source_t timeout;
    struct cm_server *server;
    struct cm_peer *next;
    bool linked;
};
struct cm_server {
    atomic_uint references;
    struct cm_policy policy;
    cm_request_handler handler;
    void *context;
    xpc_connection_t listener;
    struct cm_peer *peers;
    size_t peer_count;
    bool stopped;
};
static dispatch_queue_t cm_server_queue;
static struct cm_server *cm_current_server;
static char cm_server_queue_key;
static void cm_server_initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cm_server_queue = dispatch_queue_create("local.hx10.coolmac.ipc.server", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(cm_server_queue, &cm_server_queue_key, &cm_server_queue_key, NULL);
    });
}
static void cm_server_release(void *context) {
    struct cm_server *s = context;
    if (atomic_fetch_sub_explicit(&s->references, 1, memory_order_acq_rel) == 1) {
        cm_policy_destroy(&s->policy);
        free(s);
    }
}
static void cm_peer_finalize(void *context) {
    struct cm_peer *p = context;
    cm_server_release(p->server);
    free(p);
}
static void cm_peer_unlink(struct cm_peer *p) {
    if (!p->linked) return;
    struct cm_peer **cursor = &p->server->peers;
    while (*cursor && *cursor != p) cursor = &(*cursor)->next;
    if (*cursor) *cursor = p->next;
    p->linked = false;
    --p->server->peer_count;
    if (p->timeout) {
        dispatch_source_cancel(p->timeout);
        dispatch_release(p->timeout);
        p->timeout = NULL;
    }
    xpc_connection_cancel(p->connection);
    xpc_release(p->connection);
}
static void cm_server_stop_on_queue(struct cm_server *s) {
    if (!s || s->stopped) return;
    s->stopped = true;
    if (cm_current_server == s) cm_current_server = NULL;
    while (s->peers) cm_peer_unlink(s->peers);
    if (s->listener) {
        xpc_connection_cancel(s->listener);
        xpc_release(s->listener);
        s->listener = NULL;
    }
    cm_server_release(s); /* global ownership; callbacks retain their own server */
}
static void cm_reply_error(xpc_object_t reply, xpc_connection_t peer, const char *error) {
    xpc_dictionary_set_string(reply, "error", error);
    xpc_connection_send_message(peer, reply);
}
static bool cm_authorized(xpc_object_t message, xpc_connection_t peer,
                          const struct cm_policy *policy, uint32_t *uid, int32_t *pid) {
    if (xpc_dictionary_get_remote_connection(message) != peer) return false;
    uid_t sender_uid = xpc_connection_get_euid(peer);
    pid_t sender_pid = xpc_connection_get_pid(peer);
    if (sender_uid != policy->uid || sender_pid <= 0) return false;
    SecCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    bool allowed = false;
    /* This resolves the kernel audit token ATTACHED TO THIS MESSAGE, not a PID,
     * a disk path, bundle identifier, claimed UID or caller-supplied audit data. */
    if (SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &code) != errSecSuccess) goto out;
    if (SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL) != errSecSuccess) goto out;
    if (SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &information) != errSecSuccess) goto out;
    CFTypeRef hash = CFDictionaryGetValue(information, kSecCodeInfoUnique);
    allowed = hash && CFGetTypeID(hash) == CFDataGetTypeID() && CFSetContainsValue(policy->hashes, hash);
    if (allowed) allowed = SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL) == errSecSuccess;
    if (allowed) { *uid = (uint32_t)sender_uid; *pid = (int32_t)sender_pid; }
out:
    if (information) CFRelease(information);
    if (code) CFRelease(code);
    return allowed;
}
static void cm_server_message(struct cm_peer *p, xpc_object_t message) {
    if (xpc_get_type(message) == XPC_TYPE_ERROR) { cm_peer_unlink(p); return; }
    if (p->server->stopped || xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply) return; /* all public operations require a reply context */
    uint32_t uid = 0;
    int32_t pid = 0;
    if (!cm_authorized(message, p->connection, &p->server->policy, &uid, &pid)) {
        cm_reply_error(reply, p->connection, "unauthorized: sender UID or dynamic code signature is not authorized");
        xpc_release(reply);
        return;
    }
    xpc_object_t data = xpc_dictionary_get_value(message, "json");
    if (xpc_dictionary_get_count(message) != 1 || !data || xpc_get_type(data) != XPC_TYPE_DATA ||
        !cm_valid_json(xpc_data_get_bytes_ptr(data), xpc_data_get_length(data), CM_REQUEST_MAX_BYTES)) {
        cm_reply_error(reply, p->connection, "invalid_request: expected a JSON object of at most 16384 UTF-8 bytes");
        xpc_release(reply);
        return;
    }
    size_t length = xpc_data_get_length(data);
    char *json = malloc(length + 1);
    if (!json) { cm_reply_error(reply, p->connection, "out_of_memory: cannot copy request"); xpc_release(reply); return; }
    memcpy(json, xpc_data_get_bytes_ptr(data), length);
    json[length] = '\0';
    char *response = p->server->handler(json, uid, pid, p->server->context);
    free(json);
    size_t response_length = response ? strnlen(response, CM_RESPONSE_MAX_BYTES + 1) : 0;
    if (!cm_valid_json(response, response_length, CM_RESPONSE_MAX_BYTES))
        cm_reply_error(reply, p->connection, "invalid_response: handler must return a JSON object of at most 65536 UTF-8 bytes");
    else {
        xpc_dictionary_set_data(reply, "json", response, response_length);
        xpc_connection_send_message(p->connection, reply);
    }
    free(response);
    xpc_release(reply);
}
int cm_server_start(const char *service, const char *manifest_path, cm_request_handler handler, void *context) {
    if (!service || strcmp(service, CM_MACH_SERVICE) || !handler || !manifest_path) return EINVAL;
    cm_server_initialize();
    __block int result = 0;
    dispatch_block_t start = ^{
        if (cm_current_server) { result = EALREADY; return; }
        struct cm_server *s = calloc(1, sizeof(*s));
        if (!s) { result = ENOMEM; return; }
        atomic_init(&s->references, 1);
        result = cm_policy_load(manifest_path, &s->policy);
        if (result) { cm_server_release(s); return; }
        s->handler = handler;
        s->context = context;
        s->listener = xpc_connection_create_mach_service(CM_MACH_SERVICE, cm_server_queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!s->listener) { result = ENOMEM; cm_server_release(s); return; }
        atomic_fetch_add_explicit(&s->references, 1, memory_order_relaxed);
        xpc_connection_set_context(s->listener, s);
        xpc_connection_set_finalizer_f(s->listener, cm_server_release);
        xpc_connection_set_event_handler(s->listener, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                if (!s->stopped) {
                    os_log_error(OS_LOG_DEFAULT, "CoolMac XPC listener failed; verify launchd MachServices registration");
                    cm_server_stop_on_queue(s);
                }
                return;
            }
            if (xpc_get_type(event) != XPC_TYPE_CONNECTION) return;
            xpc_connection_t connection = (xpc_connection_t)event;
            if (s->stopped || s->peer_count >= CM_MAX_PEERS) {
                xpc_connection_set_event_handler(connection, ^(xpc_object_t ignored) { (void)ignored; });
                xpc_connection_activate(connection);
                xpc_connection_cancel(connection);
                return;
            }
            struct cm_peer *p = calloc(1, sizeof(*p));
            if (!p) {
                xpc_connection_set_event_handler(connection, ^(xpc_object_t ignored) { (void)ignored; });
                xpc_connection_activate(connection);
                xpc_connection_cancel(connection);
                return;
            }
            p->connection = connection;
            p->server = s;
            p->linked = true;
            p->next = s->peers;
            s->peers = p;
            ++s->peer_count;
            atomic_fetch_add_explicit(&s->references, 1, memory_order_relaxed);
            xpc_retain(connection);
            xpc_connection_set_target_queue(connection, cm_server_queue);
            xpc_connection_set_context(connection, p);
            xpc_connection_set_finalizer_f(connection, cm_peer_finalize);
            xpc_connection_set_event_handler(connection, ^(xpc_object_t message) { cm_server_message(p, message); });
            /* One short-lived transport per request; never a control lease.
             * Bound idle peers so untrusted clients cannot hold all slots forever. */
            p->timeout = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, cm_server_queue);
            xpc_retain(connection); /* timer keeps p's connection/finalizer alive */
            dispatch_source_set_event_handler(p->timeout, ^{ cm_peer_unlink(p); });
            dispatch_source_set_cancel_handler(p->timeout, ^{ xpc_release(connection); });
            dispatch_source_set_timer(p->timeout, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                      DISPATCH_TIME_FOREVER, 0);
            dispatch_resume(p->timeout);
            xpc_connection_activate(connection);
        });
        cm_current_server = s;
        xpc_connection_activate(s->listener);
    };
    if (dispatch_get_specific(&cm_server_queue_key)) start();
    else dispatch_sync(cm_server_queue, start);
    return result;
}
void cm_server_stop(void) {
    cm_server_initialize();
    dispatch_block_t stop = ^{ cm_server_stop_on_queue(cm_current_server); };
    if (dispatch_get_specific(&cm_server_queue_key)) stop();
    else dispatch_sync(cm_server_queue, stop);
}

struct cm_client {
    atomic_uint references;
    bool completed;
    xpc_connection_t connection;
    dispatch_queue_t queue;
    void (*completion)(const char *, const char *, void *);
    void *context;
};
static void cm_client_release(struct cm_client *c) {
    if (atomic_fetch_sub_explicit(&c->references, 1, memory_order_acq_rel) == 1) {
        dispatch_release(c->queue);
        free(c);
    }
}
/* Only called on c->queue: reply/timeout races cannot resume a continuation twice. */
static void cm_client_finish(struct cm_client *c, const char *response, const char *error) {
    if (c->completed) return;
    c->completed = true;
    void (*completion)(const char *, const char *, void *) = c->completion;
    void *context = c->context;
    c->completion = NULL;
    c->context = NULL;
    if (c->connection) {
        xpc_connection_cancel(c->connection);
        xpc_release(c->connection);
        c->connection = NULL;
    }
    completion(response, error, context);
}
static const char *cm_xpc_error(xpc_object_t error) {
    if (error == XPC_ERROR_CONNECTION_INTERRUPTED) return "connection_interrupted: helper exited before replying";
    if (error == XPC_ERROR_CONNECTION_INVALID) return "service_unavailable: helper is not installed or its connection is invalid";
    return "transport_error: XPC request failed";
}
static void cm_client_reply(struct cm_client *c, xpc_object_t reply) {
    if (c->completed) return;
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) { cm_client_finish(c, NULL, cm_xpc_error(reply)); return; }
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_count(reply) != 1) {
        cm_client_finish(c, NULL, "invalid_response: unexpected XPC envelope"); return;
    }
    xpc_object_t error = xpc_dictionary_get_value(reply, "error");
    if (error) {
        const char *text = xpc_get_type(error) == XPC_TYPE_STRING ? xpc_string_get_string_ptr(error) : NULL;
        size_t length = text ? strnlen(text, CM_ERROR_MAX_BYTES + 1) : 0;
        if (!length || length > CM_ERROR_MAX_BYTES)
            cm_client_finish(c, NULL, "invalid_response: invalid transport error");
        else cm_client_finish(c, NULL, text);
        return;
    }
    xpc_object_t data = xpc_dictionary_get_value(reply, "json");
    if (!data || xpc_get_type(data) != XPC_TYPE_DATA ||
        !cm_valid_json(xpc_data_get_bytes_ptr(data), xpc_data_get_length(data), CM_RESPONSE_MAX_BYTES)) {
        cm_client_finish(c, NULL, "invalid_response: expected a JSON object of at most 65536 UTF-8 bytes"); return;
    }
    size_t length = xpc_data_get_length(data);
    char *response = malloc(length + 1);
    if (!response) { cm_client_finish(c, NULL, "out_of_memory: cannot copy response"); return; }
    memcpy(response, xpc_data_get_bytes_ptr(data), length);
    response[length] = '\0';
    cm_client_finish(c, response, NULL);
    free(response);
}
void cm_client_request(const char *service, const char *json,
                       void (*completion)(const char *, const char *, void *), void *context) {
    if (!completion) return;
    if (!service || strcmp(service, CM_MACH_SERVICE)) {
        completion(NULL, "invalid_service: only the fixed CoolMac Mach service is allowed", context); return;
    }
    size_t length = json ? strnlen(json, CM_REQUEST_MAX_BYTES + 1) : 0;
    if (!cm_valid_json(json, length, CM_REQUEST_MAX_BYTES)) {
        completion(NULL, "invalid_request: expected a JSON object of at most 16384 UTF-8 bytes", context); return;
    }
    struct cm_client *c = calloc(1, sizeof(*c));
    if (!c) { completion(NULL, "out_of_memory: cannot allocate request", context); return; }
    atomic_init(&c->references, 1);
    c->completion = completion;
    c->context = context;
    c->queue = dispatch_queue_create("local.hx10.coolmac.ipc.client", DISPATCH_QUEUE_SERIAL);
    /* System bootstrap only: never resolve a user-session service with this name. */
    c->connection = xpc_connection_create_mach_service(CM_MACH_SERVICE, c->queue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!c->connection) {
        completion(NULL, "out_of_memory: cannot allocate XPC connection", context);
        cm_client_release(c);
        return;
    }
    xpc_connection_set_event_handler(c->connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_activate(c->connection);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(message, "json", json, length);
    /* Each outstanding block owns one reference, even after completion.
     * Cancellation delivers the outstanding reply handler with an XPC error.
     * The timeout block always releases its reference at the 3-second deadline. */
    atomic_fetch_add_explicit(&c->references, 2, memory_order_relaxed);
    xpc_connection_send_message_with_reply(c->connection, message, c->queue, ^(xpc_object_t reply) {
        cm_client_reply(c, reply);
        cm_client_release(c);
    });
    xpc_release(message);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, CM_CLIENT_TIMEOUT_SECONDS * NSEC_PER_SEC), c->queue, ^{
        cm_client_finish(c, NULL, "timeout: helper did not respond within 3 seconds");
        cm_client_release(c);
    });
    cm_client_release(c);
}
int cm_code_hash(const char *path, char *output, size_t capacity) {
    if (output && capacity) output[0] = '\0';
    if (!path || path[0] != '/' || !output || capacity < CM_CODE_HASH_CAPACITY) return EINVAL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return EINVAL;
    SecStaticCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    OSStatus result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    CFRelease(url);
    if (result) goto out;
    result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, NULL);
    if (result) goto out;
    result = SecCodeCopySigningInformation(code, kSecCSDefaultFlags, &information);
    if (result) goto out;
    CFTypeRef hash = CFDictionaryGetValue(information, kSecCodeInfoUnique);
    if (!hash || CFGetTypeID(hash) != CFDataGetTypeID() || CFDataGetLength(hash) != 20) {
        result = errSecCSUnsigned; goto out;
    }
    const UInt8 *bytes = CFDataGetBytePtr(hash);
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < 20; ++i) {
        output[i * 2] = hex[bytes[i] >> 4];
        output[i * 2 + 1] = hex[bytes[i] & 15];
    }
    output[40] = '\0';
out:
    if (information) CFRelease(information);
    if (code) CFRelease(code);
    return (int)result;
}

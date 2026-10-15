#ifndef COOLMAC_CIPC_H
#define COOLMAC_CIPC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CM_MACH_SERVICE "local.hx10.coolmac.helper"
#define CM_REQUEST_MAX_BYTES (16u * 1024u)
#define CM_RESPONSE_MAX_BYTES (64u * 1024u)
#define CM_CLIENT_TIMEOUT_SECONDS 3
#define CM_CODE_HASH_CAPACITY 41u /* 20-byte cdhash, lowercase hex, trailing NUL. */

/*
 * JSON is a UTF-8 object, without embedded NULs. The wire envelope contains only
 * "json" (XPC data); errors use only "error" (a bounded XPC string).
 * The handler owns neither json nor context; json is valid during the call.
 * Return a malloc-allocated, NUL-terminated response; the bridge always frees it.
 * Calls are serialized. uid/pid are kernel-provided XPC peer credentials, never
 * JSON claims; code identity is verified separately from each message's audit
 * token. The guardian must enforce operation/session/control-user policy.
 */
typedef char *(*cm_request_handler)(const char *json, uint32_t uid, int32_t pid, void *context);

/*
 * Only CM_MACH_SERVICE is accepted. Returns 0 or a positive errno value.
 * manifest_path is trusted server configuration, never supplied over IPC.
 * Requires a root:wheel regular file, not a symlink, without group/world write
 * permission or extended ACLs. Its plist contains authorizedUID (integer),
 * clientCDHashes and cliCDHashes (arrays of 40-character hex strings).
 * The policy is frozen until stop/start; only root installation may replace it.
 * Starts asynchronously without running a dispatch/main loop. 0 means locally
 * activated, not confirmation from launchd; asynchronous failures are os_logged.
 */
int cm_server_start(const char *service, const char *manifest_path,
                    cm_request_handler handler, void *context);

/* Synchronous handler barrier; may also be called from inside the handler. */
void cm_server_stop(void);

/*
 * Exactly one completion when completion != NULL, including invalid input.
 * May complete inline for invalid input; otherwise runs on an internal queue.
 * Has a 3-second local timeout. response/error are mutually exclusive and valid
 * only during completion; copy before returning. No connection-scoped leases.
 */
void cm_client_request(const char *service, const char *json,
                       void (*completion)(const char *response, const char *error, void *context),
                       void *context);

/*
 * Local packaging/diagnostic API, NOT exposed over XPC. Validate a final signed
 * file/bundle and return its native-architecture kSecCodeInfoUnique cdhash.
 * Caller must prevent concurrent modification and re-signing after this call.
 * capacity >= CM_CODE_HASH_CAPACITY. Returns 0, positive errno or negative
 * Security OSStatus; output is empty on failure when capacity permits.
 */
int cm_code_hash(const char *path, char *output, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif

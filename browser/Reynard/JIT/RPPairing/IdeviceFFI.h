//
//  IdeviceFFI.h
//  Reynard
//
//  Created by Minh Ton on 11/3/26.
//

#ifndef IdeviceFFI_h
#define IdeviceFFI_h

#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>

typedef struct AdapterHandle AdapterHandle;
typedef struct DebugProxyHandle DebugProxyHandle;
typedef struct DebugserverCommandHandle DebugserverCommandHandle;
// HeartbeatClientHandle, and the four heartbeat_* declarations that used
// it, were removed - see fix_delete_dead_transport_code.py. Nothing
// assigned a heartbeat client, and the only code that called through
// them was a startHeartbeat with no caller.
typedef struct ImageMounterHandle ImageMounterHandle;
typedef struct LockdowndClientHandle LockdowndClientHandle;
typedef struct RemoteServerHandle RemoteServerHandle;
typedef struct RpPairingFileHandle RpPairingFileHandle;
typedef struct RsdHandshakeHandle RsdHandshakeHandle;

typedef void *plist_t;

typedef struct IdeviceFfiError {
    int32_t code;
    int32_t sub_code;
    const char *message;
} IdeviceFfiError;

IdeviceFfiError *rp_pairing_file_read(const char *path,
                                      RpPairingFileHandle **out);
void rp_pairing_file_free(RpPairingFileHandle *handle);

IdeviceFfiError *
tunnel_create_rppairing(const struct sockaddr *addr, socklen_t addr_len,
                        const char *hostname, RpPairingFileHandle *pairing_file,
                        const char *(*pin_callback)(void *context),
                        void *pin_context, AdapterHandle **out_adapter,
                        RsdHandshakeHandle **out_handshake);

IdeviceFfiError *lockdownd_get_value(LockdowndClientHandle *client,
                                     const char *key, const char *domain,
                                     plist_t *out_plist);
void lockdownd_client_free(LockdowndClientHandle *handle);

IdeviceFfiError *lockdownd_connect_rsd(AdapterHandle *provider,
                                       RsdHandshakeHandle *handshake,
                                       LockdowndClientHandle **client);

IdeviceFfiError *image_mounter_connect_rsd(AdapterHandle *provider,
                                           RsdHandshakeHandle *handshake,
                                           ImageMounterHandle **client);
void image_mounter_free(ImageMounterHandle *handle);
IdeviceFfiError *image_mounter_copy_devices(ImageMounterHandle *client,
                                            plist_t **devices,
                                            size_t *devices_len);
IdeviceFfiError *image_mounter_mount_personalized_rsd(
                                                      ImageMounterHandle *client, AdapterHandle *provider,
                                                      RsdHandshakeHandle *handshake, const uint8_t *image, size_t image_len,
                                                      const uint8_t *trust_cache, size_t trust_cache_len,
                                                      const uint8_t *build_manifest, size_t build_manifest_len,
                                                      const void *info_plist, uint64_t unique_chip_id);

void adapter_free(AdapterHandle *handle);

void rsd_handshake_free(RsdHandshakeHandle *handle);

IdeviceFfiError *remote_server_connect_rsd(AdapterHandle *provider,
                                           RsdHandshakeHandle *handshake,
                                           RemoteServerHandle **handle);
void remote_server_free(RemoteServerHandle *handle);

// REMOVED process_control_new / process_control_free /
// process_control_disable_memory_limit and the ProcessControlHandle
// typedef - see fix_delete_dead_errors_and_helper_code.py. JITEnabler.m
// took the calls out (its own REMOVED note says so); the declarations
// outlived them by a whole architecture. Repo-wide, every surviving
// mention of the four is prose inside a comment.
IdeviceFfiError *debug_proxy_connect_rsd(AdapterHandle *provider,
                                         RsdHandshakeHandle *handshake,
                                         DebugProxyHandle **handle);
void debug_proxy_free(DebugProxyHandle *handle);
IdeviceFfiError *debug_proxy_send_command(DebugProxyHandle *handle,
                                          DebugserverCommandHandle *command,
                                          char **response);
IdeviceFfiError *debug_proxy_read_response(DebugProxyHandle *handle,
                                           char **response);
// Aborts any in-flight call on this proxy, releasing the thread blocked
// inside it. See fix_debug_proxy_cancellation.py.
IdeviceFfiError *debug_proxy_cancel(DebugProxyHandle *handle);

// Signature taken verbatim from the idevice library's own generated
// header - see fix_batch_prepare_memory_region.py. Needed to pipeline
// region preparation instead of issuing one serialised round trip per
// packet.
//
// MOVED down one declaration - see
// fix_swift_deadcode_and_stale_comments.py. It sat above
// debug_proxy_cancel, which is cancellation and belongs to
// fix_debug_proxy_cancellation.py; this is the batching primitive that
// provenance is about.
IdeviceFfiError *debug_proxy_send_raw(DebugProxyHandle *handle,
                                      const uint8_t *data,
                                      uintptr_t len);
IdeviceFfiError *debug_proxy_send_ack(DebugProxyHandle *handle);
void debug_proxy_set_ack_mode(DebugProxyHandle *handle, int enabled);

DebugserverCommandHandle *debugserver_command_new(const char *name,
                                                  const char *const *argv,
                                                  uintptr_t argv_count);
void debugserver_command_free(DebugserverCommandHandle *command);

void idevice_data_free(uint8_t *data, uintptr_t len);
void idevice_error_free(IdeviceFfiError *err);
void idevice_string_free(char *string);

void plist_free(plist_t plist);
// REMOVED plist_get_string_val - see
// fix_delete_dead_errors_and_helper_code.py. Declared, never called: the
// tree's one lockdownd_get_value (JITSupport.m, UniqueChipID) reads its
// node with plist_get_uint_val below.
void plist_get_uint_val(plist_t node, uint64_t *val);

// Copied directly from idevice.h (the underlying Rust library's own
// header) - see fix_enable_idevice_native_logging.py's docstring.
typedef enum IdeviceLoggerError {
    IdeviceLoggerSuccess = 0,
    IdeviceLoggerFileError = -1,
    IdeviceLoggerAlreadyInitialized = -2,
    IdeviceLoggerInvalidPathString = -3,
} IdeviceLoggerError;

typedef enum IdeviceLogLevel {
    IdeviceLogDisabled = 0,
    IdeviceLogError = 1,
    IdeviceLogWarn = 2,
    IdeviceLogInfo = 3,
    IdeviceLogDebug = 4,
    IdeviceLogTrace = 5,
} IdeviceLogLevel;

enum IdeviceLoggerError idevice_init_logger(enum IdeviceLogLevel console_level,
                                            enum IdeviceLogLevel file_level,
                                            char *file_path);

#endif /* IdeviceFFI_h */

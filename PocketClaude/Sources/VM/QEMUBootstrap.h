// Bootstrap for qemu-aarch64-softmmu loaded from an embedded framework.
// The frameworks come from UTM-SE.ipa (TCTI-interpreter build, matches
// Pocket Claude's accepted "slow mode" — spec sections 2 and 6). Entry
// points are qemu_init(argc, argv, envp) followed by a blocking
// qemu_main_loop(); patterned on utmapp/UTM's QEMULauncher/Bootstrap.c.

#ifndef POCKETCLAUDE_QEMU_BOOTSTRAP_H
#define POCKETCLAUDE_QEMU_BOOTSTRAP_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Load qemu-aarch64-softmmu.framework from the app bundle and run it.
// argv MUST include argv[0] (conventionally the process/dylib name).
// Blocks until qemu_main_loop returns (VM shutdown). Returns 0 on success,
// non-zero on dlopen/dlsym failure. Any C strings passed in must remain
// live for the duration of the call.
int pocket_qemu_run(const char *dylib_path, int argc, const char **argv);

// Decompress a zstd-compressed file to a destination path using
// libzstd from the embedded zstd.1.framework. Returns 0 on success,
// negative on error.
int pocket_zstd_decompress_file(const char *zstd_framework_path,
                                const char *src_path,
                                const char *dst_path);

#ifdef __cplusplus
}
#endif

#endif

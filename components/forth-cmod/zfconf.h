/* zForth configuration for ESP32 / psi.
 *
 * Tuned for our actual workload: build a system prompt at boot,
 * possibly run agent-supplied Forth in the future. We don't need
 * floating point, so cell type is int32_t — saves memory and avoids
 * pulling in newlib's softfloat. Dictionary 2 KiB is enough for the
 * core primitives + our prompt-builder; data/return stacks 32 cells
 * each (256 bytes total). Total RAM: ~2.6 KiB per context.
 */
#ifndef zfconf
#define zfconf

#define ZF_ENABLE_TRACE 0
#define ZF_ENABLE_BOUNDARY_CHECKS 1
#define ZF_ENABLE_BOOTSTRAP 1
#define ZF_ENABLE_TYPED_MEM_ACCESS 0

typedef int32_t zf_cell;
#define ZF_CELL_FMT "%d"
#define ZF_SCAN_FMT "%d"

typedef int zf_int;

typedef uint16_t zf_addr;
#define ZF_ADDR_FMT "%04x"

/* 8 KiB dictionary fits zforth's bootstrap primitives + the
 * core.zf-equivalent standard library psi loads on init + room for
 * agent-supplied definitions. The dictionary is the only growable
 * region; everything else is a fixed allocation. */
#define ZF_DICT_SIZE 8192
#define ZF_DSTACK_SIZE 32
#define ZF_RSTACK_SIZE 32

#endif

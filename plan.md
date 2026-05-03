# Bare-Metal Filesystem Plan

Goal: make psi usable on hosts without a POSIX filesystem while preserving the
current desktop behavior.

## Model

Split storage into explicit capabilities:

- `embedded_resources`: read-only resources compiled into the binary.
- `ramfs`: small volatile read/write storage owned by the process.
- `filesystem`: persistent host filesystem, POSIX today.

Do not make embedded resources pretend to be a normal filesystem. They are a
separate read-only namespace.

## Namespaces

Use explicit prefixes:

- `@embedded/name`: read from compiled resources.
- `@mem/path`: read/write RAM filesystem.
- plain paths: host filesystem when available.

For a no-host-filesystem build, plain paths may later route into a RAMFS sandbox,
but the first step should require `@mem/` so behavior is obvious.

## First Implementation Step

Add a RAMFS backend without changing normal file behavior:

1. Add `include/psi/ramfs.h` and `src/core/ramfs.c`.
2. Store files in memory with a simple normalized path key.
3. Support:
   - read file
   - write/replace file
   - append file
   - exists
   - file type
   - list directory
   - mkdir_p
   - tempfile path
4. Route only `@mem/...` paths from the existing Lua primitives in
   `src/lua/vm.c`.
5. Keep ordinary paths on the existing POSIX code path.

Initial limits:

- Total RAMFS bytes: configurable, default 256 KiB or 1 MiB.
- Max file count: fixed small limit, e.g. 256.
- No permissions model.
- `file_write_secure` is accepted but only means "write into RAMFS"; no chmod.
- Atomic writes replace the in-memory file pointer.

## Capability Reporting

Extend `psi.runtime_info()` with a `capabilities` table:

- `embedded_resources`
- `ramfs`
- `filesystem`
- `process`
- `http`
- `tui`
- `env`
- `stdio`

For the initial desktop build:

- `embedded_resources=true`
- `ramfs=true`
- `filesystem=true`

## Lua Policy

Update Lua code to consult capabilities instead of assuming host storage.

When `filesystem=false` but `ramfs=true`:

- Session state is memory-backed.
- Temp/spill files use `@mem/tmp/...`.
- `read`, `write`, `edit`, and `ls` can work for `@mem/...`.
- `read` can still read `@embedded/...`.
- Project discovery, user extensions, prompt dirs, auth files, and settings
  files are disabled unless another backend provides them.

When both `filesystem=false` and `ramfs=false`:

- Session state is in-memory only.
- File mutation and listing tools are not registered.
- `read` only supports embedded resources.

Process-backed tools remain separate:

- `bash`, shell-backed `grep`, and shell-backed `find` require
  `process=true`.
- RAMFS does not imply shell support.

## Later Refactor

After RAMFS works, introduce a common filesystem interface:

```c
struct psi_fs_ops {
    char *(*cwd)(void *userdata);
    int (*exists)(void *userdata, const char *path);
    int (*read_file)(void *userdata, const char *path, char **out, size_t *len);
    int (*write_file)(void *userdata, const char *path, const char *data, size_t len, int secure);
    int (*append_file)(void *userdata, const char *path, const char *data, size_t len);
    int (*mkdir_p)(void *userdata, const char *path);
    int (*list_dir)(void *userdata, const char *path, char ***out, size_t *count);
};
```

Backends:

- `fs_embedded`: read-only resource namespace.
- `fs_ram`: volatile RAM filesystem.
- `fs_posix`: current persistent host filesystem.
- future `fs_esp_vfs`: ESP-IDF VFS, SPIFFS, LittleFS, or FATFS.

## ESP32 Target Shape

First ESP32 target should use:

- embedded Lua/resources
- RAMFS
- no POSIX process execution
- no TUI
- HTTP only after a backend is selected

Persistent ESP32 storage can come later behind the same filesystem interface.

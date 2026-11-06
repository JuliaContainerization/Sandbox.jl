/* Copyright (c) 2023 Julia Computing Inc and contributors */
#define _GNU_SOURCE

/*
  userns_sandbox: runs a command in a sandbox made of a rootfs and an ordered list of
  mount operations.

    userns_sandbox [OPTION...] [OPERATION...] -- COMMAND [ARG...]

  The rootfs is mounted as an overlay, whose changes go to the `--persist` directory, or
  to a tmpfs that is gone when the sandbox exits.  A procfs for the sandbox's PID
  namespace goes on /proc.  Then the operations run in the order given, each on a
  destination in that root: destinations are resolved as if the root were `/`, so that
  symlinks in the rootfs can't lead out of it, and what is missing of them is created.
  Finally, the mounts are locked in a nested user namespace, and the command runs as the
  child of an init of its own PID namespace.

  Unprivileged mode (the default) sets all of this up in a new user namespace.  When
  the kernel doesn't allow mounting an overlayfs in a user namespace, the mounts can be
  made as real root instead (`--privileged`, through sudo), before the sandbox drops to
  the calling user, whose ids sudo passes in SUDO_UID and SUDO_GID.

  To try it out:

    make -C deps
    mkdir -p /tmp/workspace
    deps/userns_sandbox --verbose --rootfs $rootfs_dir \
        --bind /tmp/workspace /workspace --cd /workspace -- /bin/bash
*/

#include "userns_common.h"
#include <grp.h>
#include <stdarg.h>
#include <sys/file.h>

enum op_type {
  OP_BIND,
  OP_OVERLAY,
  OP_TMPFS,
  OP_DEVPTS,
  OP_CGROUP,
  OP_SYMLINK,
};
#define OP_RO 1
#define OP_TRY 2
#define OP_DEV 4

struct op {
  int type, flags;
  // BIND and OVERLAY: the host path; TMPFS: the mount options; SYMLINK: the target
  const char *arg;
  const char *dest;
  // BIND and OVERLAY: `arg`, opened before anything is mounted; -1 for a missing
  // optional source
  int src_fd;
};

static struct op *ops = NULL;
static int n_ops = 0;

static const char *sandbox_root = NULL;
static const char *new_cd = NULL;
static const char *persist_dir = NULL;
static const char *hostname = NULL;
static const char *tmpfs_size = NULL;

enum {
  UNPRIVILEGED_CONTAINER_MODE,
  PRIVILEGED_CONTAINER_MODE,
};
static int execution_mode = UNPRIVILEGED_CONTAINER_MODE;

// Whether the overlays have the `userxattr` option; see `mount_persisted_root()`.
static int userxattr = 0;

// Device nodes and setuid/setgid bits in the image must not take effect.  Mounts made
// in a user namespace other than the initial one ignore device nodes anyway, but in
// privileged mode we mount as real root.
static const unsigned long overlay_flags = MS_NODEV | MS_NOSUID;


/**** Command line ****/

static void print_help() {
  fputs(
    "Usage: userns_sandbox [OPTION...] [OPERATION...] -- COMMAND [ARG...]\n"
    "\n"
    "Options:\n"
    "  --rootfs DIR              the root of the sandbox (required)\n"
    "  --persist DIR             keep the changes to the rootfs and overlays in DIR,\n"
    "                            which only one sandbox at a time may use\n"
    "  --tmpfs-size SIZE         size of the tmpfs that holds the changes without --persist\n"
    "  --uid UID, --gid GID      the sandbox's user and group (default 0)\n"
    "  --privileged              mount as root, then run as the user sudo was called by\n"
    "  --hostname NAME           the sandbox's hostname\n"
    "  --cd DIR                  the command's working directory, created if missing\n"
    "  --verbose                 tell what is being set up\n"
    "\n"
    "Operations, run in the order given, after /proc is mounted:\n"
    "  --bind SRC DEST           bind the host path SRC at DEST, recursively, with\n"
    "                            device nodes and setuid bits that don't take effect\n"
    "  --dev-bind SRC DEST       the same, where device nodes work\n"
    "  --ro-bind, --ro-dev-bind  the same, read-only including the mounts below it\n"
    "  --bind-try, --dev-bind-try, --ro-bind-try, --ro-dev-bind-try\n"
    "                            the same, skipped if SRC doesn't exist\n"
    "  --overlay SRC DEST        an overlay of the host directory SRC at DEST, whose\n"
    "                            changes go with those of the rootfs\n"
    "  --ro-overlay SRC DEST     the same, read-only, which shows the changes made\n"
    "                            through an earlier --overlay at DEST\n"
    "  --tmpfs DEST OPTIONS      a tmpfs, with OPTIONS such as \"mode=1777,size=1G\"\n"
    "  --devpts DEST             a new instance of devpts\n"
    "  --cgroup DEST             a read-only view of the sandbox's cgroup\n"
    "  --symlink TARGET DEST     a symlink at DEST to TARGET\n"
    "\n"
    "  --help                    print this message and exit\n",
    stderr);
}

static void usage_error(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("ERROR: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputs(" (see --help)\n", stderr);
  va_end(ap);
  exit(EXIT_SANDBOX_FAILED);
}

// The option being parsed, for messages.
static const char *current_opt = NULL;

static const char *take_arg(int *i, int argc, char **argv) {
  if (*i + 1 >= argc || strcmp(argv[*i + 1], "--") == 0) {
    usage_error("%s takes more arguments", current_opt);
  }
  return argv[++*i];
}

static void set_once(const char **var, int *i, int argc, char **argv) {
  if (*var != NULL) {
    usage_error("%s given more than once", current_opt);
  }
  *var = take_arg(i, argc, argv);
}

static id_t parse_id(const char *s, const char *what) {
  char *end;
  errno = 0;
  unsigned long id = strtoul(s, &end, 10);
  if (s[0] < '0' || s[0] > '9' || *end != '\0' || errno != 0 || id >= (id_t)-1) {
    usage_error("invalid %s \"%s\"", what, s);
  }
  return (id_t)id;
}

// Whether `path` is `prefix` or below it, comparing components.
static int path_within(const char *path, const char *prefix) {
  for (;;) {
    while (*path == '/') path++;
    while (*prefix == '/') prefix++;
    if (*prefix == '\0') {
      return 1;
    }
    size_t n = strcspn(prefix, "/");
    if (strncmp(path, prefix, n) != 0 || (path[n] != '/' && path[n] != '\0')) {
      return 0;
    }
    path += n;
    prefix += n;
  }
}

static void add_op(int type, int flags, const char *arg, const char *dest) {
  if (dest[0] != '/') {
    usage_error("destination \"%s\" is not absolute", dest);
  }
  // The init mounts the procfs of its PID namespace over /proc after the operations,
  // which would hide anything they put there.
  if (path_within(dest, "/proc")) {
    usage_error("destination \"%s\" is in /proc, which the sandbox mounts itself", dest);
  }
  if ((type == OP_BIND || type == OP_OVERLAY) && arg[0] != '/') {
    usage_error("source \"%s\" is not absolute", arg);
  }
  for (int i = 0; type == OP_OVERLAY && i < n_ops; i++) {
    // Each overlay keeps its changes in a directory named after its destination.
    if (ops[i].type == OP_OVERLAY && strcmp(ops[i].dest, dest) == 0) {
      usage_error("more than one overlay at \"%s\"", dest);
    }
  }
  ops = realloc(ops, (n_ops + 1) * sizeof(*ops));
  check(ops != NULL);
  ops[n_ops++] = (struct op) {.type = type, .flags = flags, .arg = arg, .dest = dest, .src_fd = -1};
}

// --[ro-][dev-]bind[-try]
static int parse_bind(const char *opt, int *flags) {
  *flags = 0;
  if (strncmp(opt, "--", 2) != 0) {
    return 0;
  }
  opt += 2;
  if (strncmp(opt, "ro-", 3) == 0) {
    *flags |= OP_RO;
    opt += 3;
  }
  if (strncmp(opt, "dev-", 4) == 0) {
    *flags |= OP_DEV;
    opt += 4;
  }
  if (strncmp(opt, "bind", 4) != 0) {
    return 0;
  }
  opt += 4;
  if (strcmp(opt, "-try") == 0) {
    *flags |= OP_TRY;
  } else if (*opt != '\0') {
    return 0;
  }
  return 1;
}

// Parses the options and operations, returning the index of the command.
static int parse_args(int argc, char **argv, const char **uid_arg, const char **gid_arg) {
  int i;
  for (i = 1; i < argc; i++) {
    const char *opt = current_opt = argv[i];
    int flags;
    if (strcmp(opt, "--") == 0) {
      i++;
      break;
    } else if (strcmp(opt, "--verbose") == 0) {
      verbose = 1;
    } else if (strcmp(opt, "--privileged") == 0) {
      execution_mode = PRIVILEGED_CONTAINER_MODE;
    } else if (strcmp(opt, "--rootfs") == 0) {
      set_once(&sandbox_root, &i, argc, argv);
    } else if (strcmp(opt, "--persist") == 0) {
      set_once(&persist_dir, &i, argc, argv);
    } else if (strcmp(opt, "--tmpfs-size") == 0) {
      set_once(&tmpfs_size, &i, argc, argv);
    } else if (strcmp(opt, "--hostname") == 0) {
      set_once(&hostname, &i, argc, argv);
    } else if (strcmp(opt, "--cd") == 0) {
      set_once(&new_cd, &i, argc, argv);
    } else if (strcmp(opt, "--uid") == 0) {
      set_once(uid_arg, &i, argc, argv);
    } else if (strcmp(opt, "--gid") == 0) {
      set_once(gid_arg, &i, argc, argv);
    } else if (parse_bind(opt, &flags)) {
      const char *src = take_arg(&i, argc, argv);
      add_op(OP_BIND, flags, src, take_arg(&i, argc, argv));
    } else if (strcmp(opt, "--overlay") == 0 || strcmp(opt, "--ro-overlay") == 0) {
      const char *src = take_arg(&i, argc, argv);
      add_op(OP_OVERLAY, opt[2] == 'r' ? OP_RO : 0, src, take_arg(&i, argc, argv));
    } else if (strcmp(opt, "--tmpfs") == 0) {
      const char *dest = take_arg(&i, argc, argv);
      add_op(OP_TMPFS, 0, take_arg(&i, argc, argv), dest);
    } else if (strcmp(opt, "--devpts") == 0) {
      add_op(OP_DEVPTS, 0, NULL, take_arg(&i, argc, argv));
    } else if (strcmp(opt, "--cgroup") == 0) {
      add_op(OP_CGROUP, 0, NULL, take_arg(&i, argc, argv));
    } else if (strcmp(opt, "--symlink") == 0) {
      const char *target = take_arg(&i, argc, argv);
      add_op(OP_SYMLINK, 0, target, take_arg(&i, argc, argv));
    } else {
      usage_error("unknown option \"%s\" (the command goes after `--`)", opt);
    }
  }
  if (i >= argc) {
    usage_error("no command given after `--`");
  }
  if (sandbox_root == NULL) {
    usage_error("--rootfs is required");
  }
  return i;
}


/**** Operations ****/

/*
 * Opens the sources of the bind and overlay operations, before anything is mounted, so
 * that they are the host paths the caller named rather than whatever the setup has
 * mounted there.  This happens in the mount namespace of the sandbox: mount(2) only
 * binds from mounts of the namespace it is called in.
 */
static void open_sources() {
  for (int i = 0; i < n_ops; i++) {
    struct op *op = &ops[i];
    if (op->type != OP_BIND && op->type != OP_OVERLAY) {
      continue;
    }
    op->src_fd = open(op->arg, O_PATH | O_CLOEXEC | (op->type == OP_OVERLAY ? O_DIRECTORY : 0));
    if (op->src_fd == -1 && !(errno == ENOENT && (op->flags & OP_TRY))) {
      fprintf(stderr, "ERROR: Failed to open '%s' to mount it at '%s': %s (errno %d)\n",
              op->arg, op->dest, strerror(errno), errno);
      _exit(EXIT_SANDBOX_FAILED);
    }
  }
}

static int open_dest(int root_fd, const struct op *op, mode_t create) {
  int fd = open_in_root_or_die(root_fd, op->dest, create);
  check_not_root(root_fd, fd, op->dest);
  check_not_proc(fd, op->dest);
  return fd;
}

/*
 * The name of the directories that hold an overlay's changes: its destination, with `/`
 * and `%` escaped.  Unlike a hash, that can't be the same for two destinations, and it
 * can't be "rootfs", the rootfs's.
 */
static void state_name(char *name, const char *dest) {
  size_t n = 0;
  for (const char *c = dest; *c != '\0'; c++) {
    const char *escaped = *c == '/' ? "%2F" : *c == '%' ? "%25" : NULL;
    size_t len = escaped ? 3 : 1;
    if (n + len > NAME_MAX) {
      fprintf(stderr, "ERROR: Failed to mount an overlay at '%s': the destination is too long\n", dest);
      _exit(EXIT_SANDBOX_FAILED);
    }
    memcpy(name + n, escaped ? escaped : c, len);
    n += len;
  }
  name[n] = '\0';
}

static void mount_overlay_op(int root_fd, const struct op *op, const char *work_dir,
                             uid_t uid, gid_t gid) {
  char lower[FD_PATH_SIZE], path[FD_PATH_SIZE], name[NAME_MAX + 1];
  fd_path(lower, op->src_fd);
  int fd = open_dest(root_fd, op, S_IFDIR);
  fd_path(path, fd);
  // Each overlay keeps its changes in a directory named after its destination, so that
  // a later run sees them at the same place.
  state_name(name, op->dest);
  check(TRUE == mount_overlay(lower, path, name, work_dir, userxattr, overlay_flags));
  close(fd);

  // Look the destination up again, to get the overlay rather than what it covers.
  fd = open_in_root_or_die(root_fd, op->dest, 0);
  fd_path(path, fd);
  check(0 == fchownat(fd, "", uid, gid, AT_EMPTY_PATH));
  if (op->flags & OP_RO) {
    check(0 == mount("overlay", path, "overlay", MS_REMOUNT|MS_RDONLY|overlay_flags, ""));
  }
  close(fd);
}

static void mount_tmpfs_op(int root_fd, const struct op *op, uid_t uid, gid_t gid) {
  char path[FD_PATH_SIZE];
  int fd = open_dest(root_fd, op, S_IFDIR);
  fd_path(path, fd);
  if (verbose) {
    fprintf(stderr, "--> Mounting tmpfs at %s (%s)\n", op->dest, op->arg);
  }
  if (0 != mount("tmpfs", path, "tmpfs", MS_NOSUID|MS_NODEV, op->arg)) {
    fprintf(stderr, "ERROR: Failed to mount a tmpfs at '%s' with options '%s': %s (errno %d)\n",
            op->dest, op->arg, strerror(errno), errno);
    _exit(EXIT_SANDBOX_FAILED);
  }
  close(fd);
  // Owned by the sandbox's user, as everything else we create, rather than by an
  // unmapped root in privileged mode.
  fd = open_in_root_or_die(root_fd, op->dest, 0);
  check(0 == fchownat(fd, "", uid, gid, AT_EMPTY_PATH));
  close(fd);
}

static void mount_devpts_op(int root_fd, const struct op *op) {
  char path[FD_PATH_SIZE];
  int fd = open_dest(root_fd, op, S_IFDIR);
  fd_path(path, fd);
  if (verbose) {
    fprintf(stderr, "--> Mounting devpts at %s\n", op->dest);
  }
  check(0 == mount("devpts", path, "devpts", MS_NOSUID|MS_NOEXEC, "newinstance,ptmxmode=0666"));
  close(fd);
}

/*
 * A read-only cgroup2 mount, rooted at the cgroup the sandbox was started in (the root of
 * its cgroup namespace), so that the sandbox can read its own limits (as /proc/self/cgroup
 * says `0::/`) but cannot reach any other cgroup.  At the default destination, it covers
 * the host's writable hierarchy that came in with /sys.  Without a cgroup2 hierarchy on
 * the host there is no such view to give, and an empty read-only tmpfs takes its place.
 *
 * The cgroup2 mount would share its superblock with the host's, which mount(2) refuses
 * to stack on that directly (EBUSY), and the superblock is writable, so the mount cannot
 * be asked for read-only either.  So it is mounted in a directory of a fresh tmpfs at the
 * destination, made read-only, then moved on top of that tmpfs.
 */
static void mount_cgroup_op(int root_fd, const struct op *op) {
  char path[FD_PATH_SIZE], view_path[FD_PATH_SIZE];
  const unsigned long flags = MS_NOSUID|MS_NODEV|MS_NOEXEC;
  struct statfs host_fs;
  int view = statfs("/sys/fs/cgroup", &host_fs) == 0 && host_fs.f_type == CGROUP2_SUPER_MAGIC;

  int fd = open_dest(root_fd, op, S_IFDIR);
  fd_path(path, fd);
  if (verbose) {
    fprintf(stderr, view ? "--> Mounting a read-only cgroup2 view at %s\n"
                         : "--> No cgroup2 hierarchy on the host, mounting an empty tmpfs at %s\n",
            op->dest);
  }
  check(0 == mount("tmpfs", path, "tmpfs", flags | (view ? 0 : MS_RDONLY), "size=4k,mode=0755"));
  if (!view) {
    close(fd);
    return;
  }

  int tmp_fd = open_in_root_or_die(root_fd, op->dest, 0);
  check(0 == mkdirat(tmp_fd, "view", 0700));
  char tmp_path[FD_PATH_SIZE];
  fd_path(tmp_path, tmp_fd);
  check(0 == mount(NULL, tmp_path, NULL, MS_REMOUNT|MS_BIND|MS_RDONLY|flags, NULL));
  int view_fd = openat(tmp_fd, "view", O_PATH | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC);
  check(view_fd != -1);
  fd_path(view_path, view_fd);
  if (0 != mount("cgroup2", view_path, "cgroup2", flags, NULL)) {
    fprintf(stderr, "ERROR: Failed to mount cgroup2: %s (errno %d)\n", strerror(errno), errno);
    _exit(EXIT_SANDBOX_FAILED);
  }
  close(view_fd);
  view_fd = openat(tmp_fd, "view", O_PATH | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC);
  check(view_fd != -1);
  fd_path(view_path, view_fd);
  check(0 == mount(NULL, view_path, NULL, MS_REMOUNT|MS_BIND|MS_RDONLY|flags, NULL));
  check(0 == mount(view_path, path, NULL, MS_MOVE, NULL));
  close(view_fd);
  close(tmp_fd);
  close(fd);
}

/*
 * Creates a symlink at `op->dest` to `op->arg`.  One that is already there with the same
 * target is fine (as in a persisted rootfs); anything else there is an error.
 */
static void make_symlink_op(int root_fd, const struct op *op, uid_t uid, gid_t gid) {
  char dir[PATH_MAX], target[PATH_MAX];
  check(strlen(op->dest) < sizeof(dir));
  strcpy(dir, op->dest);
  char *slash = strrchr(dir, '/');
  const char *name = slash + 1;
  if (*name == '\0' || strcmp(name, ".") == 0 || strcmp(name, "..") == 0) {
    fprintf(stderr, "ERROR: Failed to create a symlink at '%s': not a file name\n", op->dest);
    _exit(EXIT_SANDBOX_FAILED);
  }
  *slash = '\0';
  if (verbose) {
    fprintf(stderr, "--> Creating symlink %s -> %s\n", op->dest, op->arg);
  }
  int dir_fd = open_in_root_or_die(root_fd, dir[0] == '\0' ? "/" : dir, S_IFDIR);
  check_not_proc(dir_fd, op->dest);
  if (0 != symlinkat(op->arg, dir_fd, name)) {
    int saved_errno = errno;
    ssize_t len = saved_errno == EEXIST ? readlinkat(dir_fd, name, target, sizeof(target)) : -1;
    if (len != (ssize_t)strlen(op->arg) || memcmp(target, op->arg, len) != 0) {
      fprintf(stderr, "ERROR: Failed to create a symlink at '%s': %s\n", op->dest,
              saved_errno == EEXIST ? "something else is there" : strerror(saved_errno));
      _exit(EXIT_SANDBOX_FAILED);
    }
  } else {
    check(0 == fchownat(dir_fd, name, uid, gid, AT_SYMLINK_NOFOLLOW));
  }
  close(dir_fd);
}

static void run_ops(int root_fd, const char *work_dir, uid_t uid, gid_t gid) {
  for (int i = 0; i < n_ops; i++) {
    struct op *op = &ops[i];
    switch (op->type) {
      case OP_BIND:
        if (op->src_fd == -1) {
          if (verbose) {
            fprintf(stderr, "--> Skipping %s, as %s doesn't exist\n", op->dest, op->arg);
          }
        } else {
          // Setuid bits never take effect, and device nodes only with dev-, whatever
          // the source's mount allows.
          bind_mount(root_fd, op->src_fd, op->arg, op->dest,
                     MS_NOSUID | (op->flags & OP_DEV ? 0 : MS_NODEV) | (op->flags & OP_RO ? MS_RDONLY : 0));
        }
        break;
      case OP_OVERLAY:
        mount_overlay_op(root_fd, op, work_dir, uid, gid);
        break;
      case OP_TMPFS:
        mount_tmpfs_op(root_fd, op, uid, gid);
        break;
      case OP_DEVPTS:
        mount_devpts_op(root_fd, op);
        break;
      case OP_CGROUP:
        mount_cgroup_op(root_fd, op);
        break;
      case OP_SYMLINK:
        make_symlink_op(root_fd, op, uid, gid);
        break;
    }
    if (op->src_fd != -1) {
      close(op->src_fd);
      op->src_fd = -1;
    }
  }
}

/* A procfs at /proc of `root_fd`, for the PID namespace we are in. */
static void mount_proc(int root_fd) {
  char path[FD_PATH_SIZE];
  int fd = open_in_root_or_die(root_fd, "/proc", S_IFDIR);
  fd_path(path, fd);
  if (verbose) {
    fprintf(stderr, "--> Mounting procfs at /proc\n");
  }
  check(0 == mount("proc", path, "proc", MS_NOSUID|MS_NODEV|MS_NOEXEC, NULL));
  close(fd);
}

static int in_initial_user_namespace() {
  char map[64] = {0};
  unsigned int inside, outside, count;
  int fd = open("/proc/self/uid_map", O_RDONLY | O_CLOEXEC);
  check(fd != -1);
  check(read(fd, map, sizeof(map) - 1) > 0);
  close(fd);
  return sscanf(map, "%u %u %u", &inside, &outside, &count) == 3 &&
         inside == 0 && outside == 0 && count == 4294967295u;
}

/*
 * Mounts the rootfs overlay, with its changes in `work_dir`, the persist directory.
 *
 * overlayfs records what it needs (whiteouts of directories, renames) in extended
 * attributes.  It uses trusted.overlay.*, which only real root can set, unless it is
 * mounted with `userxattr` (Linux 5.11), for user.overlay.*.  In a user namespace that is
 * the only way to get them, and it works for root as well, so it comes first.  The
 * changes kept in the persist directory can only be read the way they were written, so
 * that is recorded there, in `xattrs`: "user", "trusted" (by real root), or
 * "trusted-userns" (in a user namespace, on kernels that patch overlayfs in before 5.11).
 * Once recorded, a failure to mount must not lead to another way.
 */
static void mount_persisted_root(const char *lower_dir, const char *work_dir) {
  char marker[PATH_MAX], upper[PATH_MAX], recorded[32] = {0};
  const char *trusted = in_initial_user_namespace() ? "trusted\n" : "trusted-userns\n";
  int n = snprintf(marker, sizeof(marker), "%s/xattrs", work_dir);
  check(0 < n && n < sizeof(marker));
  n = snprintf(upper, sizeof(upper), "%s/upper", work_dir);
  check(0 < n && n < sizeof(upper));
  int fd = open(marker, O_RDONLY | O_CLOEXEC);
  if (fd == -1) {
    check(errno == ENOENT);
    if (access(upper, F_OK) == 0) {
      fprintf(stderr, "ERROR: The changes in '%s' don't say how they were made (no `xattrs`)\n", persist_dir);
      _exit(EXIT_SANDBOX_FAILED);
    }
    userxattr = 1;
    if (TRUE != mount_overlay(lower_dir, sandbox_root, "rootfs", work_dir, 1, overlay_flags)) {
      check(errno == EINVAL);
      if (verbose) {
        fprintf(stderr, "--> The kernel doesn't take userxattr, mounting without it\n");
      }
      userxattr = 0;
      check(TRUE == mount_overlay(lower_dir, sandbox_root, "rootfs", work_dir, 0, overlay_flags));
    }
    fd = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    check(fd != -1);
    const char *value = userxattr ? "user\n" : trusted;
    check(write(fd, value, strlen(value)) == strlen(value));
    close(fd);
    return;
  }
  check(read(fd, recorded, sizeof(recorded) - 1) >= 0);
  close(fd);
  if (strcmp(recorded, "user\n") == 0) {
    userxattr = 1;
  } else if (strcmp(recorded, trusted) == 0) {
    userxattr = 0;
  } else {
    fprintf(stderr, "ERROR: The changes in '%s' were made %s, and this sandbox can't read them\n",
            persist_dir, strcmp(recorded, "trusted\n") == 0 ? "by real root without userxattr" :
                         strcmp(recorded, "trusted-userns\n") == 0 ? "in a user namespace without userxattr"
                                                                   : "in an unknown way (see its `xattrs`)");
    _exit(EXIT_SANDBOX_FAILED);
  }
  check(TRUE == mount_overlay(lower_dir, sandbox_root, "rootfs", work_dir, userxattr, overlay_flags));
}

/*
 * Mounts the rootfs, /proc, and everything the operations ask for, in the mount namespace
 * of the sandbox: in privileged mode, before we clone the sandbox's user namespace, and
 * in unprivileged mode within it.  `uid` and `gid` own the root and overlays.
 */
static void mount_the_world(uid_t uid, gid_t gid) {
  // systemd makes `/` a shared mount, so the mount namespace we were just given
  // shares its mounts with the host's, as peers in privileged mode, and as slaves
  // otherwise (being owned by a less privileged user namespace).  Make them private:
  // our mounts must not propagate to the host, nor the host's later mounts into
  // the sandbox.
  check(0 == mount(NULL, "/", NULL, MS_PRIVATE|MS_REC, NULL));

  open_sources();

  // The changes to the rootfs and overlays go to `persist_dir`, where later runs with
  // the same directory find them again; the caller cleans it up.  Without it, they go
  // to a tmpfs that is gone when the last process of the sandbox exits.
  //
  // overlayfs needs the tmpfs to be reachable by path while it mounts, but mounted on a
  // host directory, it would hide whatever is below that directory from the sources.
  // So it goes over the rootfs directory itself: the rootfs is opened beforehand to be
  // the overlay's lower layer, and the overlay then covers the tmpfs, which stays
  // reachable for the overlay operations through `scratch_fd`.
  const char *work_dir = persist_dir;
  const char *lower_dir = sandbox_root;
  char lower_path[FD_PATH_SIZE], scratch_path[FD_PATH_SIZE];
  int lower_fd = -1, scratch_fd = -1;
  if (persist_dir == NULL) {
    lower_fd = open_root(sandbox_root);
    fd_path(lower_path, lower_fd);
    lower_dir = lower_path;

    char options[64];
    int n = snprintf(options, sizeof(options), "size=%s", tmpfs_size ? tmpfs_size : "1G");
    check(0 < n && n < sizeof(options));
    if (0 != mount("tmpfs", lower_path, "tmpfs", 0, options)) {
      fprintf(stderr, "ERROR: Failed to mount the tmpfs for the changes to the rootfs (%s): %s (errno %d)\n",
              options, strerror(errno), errno);
      _exit(EXIT_SANDBOX_FAILED);
    }

    scratch_fd = open_root(sandbox_root);
    fd_path(scratch_path, scratch_fd);
    work_dir = scratch_path;
  }
  if (verbose) {
    fprintf(stderr, "--> Creating overlay workdir at %s\n", work_dir);
  }
  if (persist_dir == NULL) {
    // Real root sets trusted xattrs on a tmpfs.  Anyone else needs `userxattr`, which a
    // tmpfs supports since Linux 6.6; on older kernels the overlays get by without them,
    // as without the option.
    userxattr = !in_initial_user_namespace();
    if (TRUE != mount_overlay(lower_dir, sandbox_root, "rootfs", work_dir, userxattr, overlay_flags)) {
      check(errno == EINVAL && userxattr);
      userxattr = 0;
      check(TRUE == mount_overlay(lower_dir, sandbox_root, "rootfs", work_dir, 0, overlay_flags));
    }
  } else {
    mount_persisted_root(lower_dir, work_dir);
  }
  int root_fd = open_root(sandbox_root);

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox.
  check(0 == fchownat(root_fd, "", uid, gid, AT_EMPTY_PATH));

  mount_proc(root_fd);
  run_ops(root_fd, work_dir, uid, gid);

  close(root_fd);
  if (lower_fd != -1) {
    close(lower_fd);
    close(scratch_fd);
  }
}


/**** Running the command ****/

/*
 * Moves into a nested user namespace (with a mount namespace) that maps only our own
 * uid and gid.  The kernel locks every mount that is copied into a mount namespace
 * owned by a less privileged user namespace: such mounts can no longer be unmounted
 * on their own (which would reveal what they cover, such as the host's cgroup
 * hierarchy under our cgroup2 mount) and their read-only, nosuid, nodev and noexec
 * flags can no longer be cleared.
 *
 * The sandboxed processes have no capabilities over namespaces owned by the outer
 * user namespace, so new PID, UTS and IPC namespaces are created along with it for
 * them to own: as before, they may mount a procfs for their PID namespace (which a
 * nested sandbox in privileged mode does), and set the hostname.  The PID namespace
 * applies to our children: the next one becomes its init.  The cgroup namespace stays
 * the outer one, which is what keeps the cgroup2 view rooted where it is.
 */
static void lock_sandbox() {
  uid_t uid = geteuid();
  gid_t gid = getegid();

  if (verbose) {
    fprintf(stderr, "--> Locking the sandbox in a nested user namespace\n");
  }
  if (0 != unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWIPC)) {
    fprintf(stderr, "ERROR: Failed to create the nested user namespace that locks the sandbox: %s (errno %d)\n",
            strerror(errno), errno);
    _exit(EXIT_SANDBOX_FAILED);
  }
  // In privileged mode, `setuid()` reset our dumpability, which leaves our /proc
  // entries owned by an unmapped root and keeps us from writing our own maps.
  prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);
  // Ourselves, through /proc/self, which needs no getpid() (see `raw_fork()`).
  configure_user_namespace(0, uid, gid, uid, gid);

  // The sandboxed processes run as our user in this user namespace, so while we are
  // dumpable they could open our fds (the status pipe) through /proc/1/fd of their
  // PID namespace, whose init inherits this setting.  Their capabilities don't help
  // them past it: those are checked against the user namespace that owns our memory,
  // the launcher's, as we never exec.
  prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
}

/*
 * Makes the kernel SIGKILL us when the launcher dies.  We are the init of the outermost
 * PID namespace, so that takes all the sandboxed processes with us.  `status_fd` is our
 * end of the status pipe, which tells us whether the launcher already died before that:
 * `getppid()` can't, as the launcher is outside our PID namespace.
 */
static void die_with_launcher(int status_fd) {
  check(0 == prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0));
  struct pollfd pfd = {.fd = status_fd, .events = 0};
  check(0 <= poll(&pfd, 1, 0));
  if (pfd.revents & POLLERR) {
    _exit(EXIT_SANDBOX_FAILED);
  }
}

/*
 * In privileged mode, the sandbox runs as the calling user, but we were started with
 * the supplementary groups of root (as sudo sets them), which would keep giving it
 * root's group access to host files.  Drop them all: the calling user's own
 * supplementary groups are not known here (sudo does not pass them on), and looking
 * them up would need NSS, which a static binary cannot use.  The primary group
 * remains, mapped from SUDO_GID.
 *
 * Within a user namespace that denies setgroups(), as in another sandbox, whoever set
 * that up already decided the groups, and we keep them.
 */
static void drop_supplementary_groups() {
  if (setgroups(0, NULL) == 0) {
    return;
  }
  check(errno == EPERM);
  char setgroups_state[8] = {0};
  int fd = open("/proc/self/setgroups", O_RDONLY | O_CLOEXEC);
  check(fd != -1);
  check(read(fd, setgroups_state, sizeof(setgroups_state) - 1) > 0);
  close(fd);
  check(strncmp(setgroups_state, "deny", 4) == 0);
}

/*
 * Enters the root, locks the mounts, and runs the command as the child of an init of
 * its PID namespace.
 */
static int sandbox_main(int sandbox_argc, char **sandbox_argv, int *parent_pipe) {
  int status;

  // Use `pivot_root()` to avoid bad interaction between `chroot()` and `clone()`,
  // where we get an EPERM on nested sandboxing.
  if (verbose) {
    fprintf(stderr, "Entering rootfs at %s\n", sandbox_root);
  }
  check(0 == chdir(sandbox_root));
  if (syscall(SYS_pivot_root, ".", ".") == 0) {
    // Unmount `.`, which will unmount the old root, since that's the first mountpoint in this directory
    check(0 == umount2(".", MNT_DETACH));
    check(0 == chdir("/"));

    if (verbose) {
      fprintf(stderr, "--> pivot_root() succeeded and unmounted old root\n");
    }
  } else {
    check(0 == chroot(sandbox_root));
    if (verbose) {
      fprintf(stderr, "--> chroot() used since pivot_root() errored with: [%d] %s; locking the sandbox will fail\n", errno, strerror(errno));
    }
  }

  // All mounts are in place, so lock them before running anything.
  lock_sandbox();

  // Our next child is the init of the sandboxed processes' PID namespace; it reports
  // their exit status to the parent itself.  We only pass signals on to it.
  pid_t init_pid = raw_fork();
  if (init_pid != 0) {
    check(init_pid != -1);
    close(parent_pipe[1]);
    child_pid = init_pid;
    setup_signal_forwarding();
    while (waitpid(init_pid, &status, 0) == -1) {
      check(errno == EINTR);
    }
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : 1;
  }

  // Give that PID namespace its own /proc, over the (now locked) one of ours.
  int root_fd = open_root("/");
  mount_proc(root_fd);
  close(root_fd);

  // If we've got a directory to change to, do so, creating it if we need to
  if (new_cd) {
    mkpath(new_cd);
    check(0 == chdir(new_cd));
  }

  // When the main pid dies, we exit.
  if ((child_pid = raw_fork()) == 0) {
    if (verbose) {
      fprintf(stderr, "About to run `%s` ", sandbox_argv[0]);
      int argc_i;
      for( argc_i=1; argc_i<sandbox_argc; ++argc_i) {
        fprintf(stderr, "`%s` ", sandbox_argv[argc_i]);
      }
      fprintf(stderr, "\n");
    }
    execve(sandbox_argv[0], sandbox_argv, environ);
    int exec_errno = errno;
    fprintf(stderr, "ERROR: Failed to run %s: %d (%s)\n", sandbox_argv[0], exec_errno, strerror(exec_errno));

    // Flush to make sure we've said all we're going to before we _exit()
    fflush(stdout);
    fflush(stderr);
    _exit((exec_errno == ENOENT || exec_errno == ENOTDIR) ? EXIT_NOT_FOUND : EXIT_CANNOT_EXECUTE);
  }

  // We want to pass signals through to our child
  setup_signal_forwarding();

  // Let's perform normal init functions, handling signals from orphaned
  // children, etc
  for (;;) {
    pid_t reaped_pid = waitpid(-1, &status, 0);
    if (reaped_pid == -1) {
      // ECHILD would mean we missed the exit of the main pid; don't wait forever.
      check(errno == EINTR);
      continue;
    }
    if (reaped_pid == child_pid) {
      // If it was the main pid that exited, we're going to exit too.
      // If we died of a signal, return that signal + 256, which we will
      // notice on the other end as a signal.
      uint32_t reported_exit_code;
      if (WIFSIGNALED(status)) {
        reported_exit_code = 256 + WTERMSIG(status);
      } else {
        reported_exit_code = WEXITSTATUS(status);
      }
      check(sizeof(uint32_t) == write(parent_pipe[1], &reported_exit_code, sizeof(uint32_t)));
      return 0;
    }
  }
}

int main(int sandbox_argc, char **sandbox_argv) {
  int status = 0;
  pid_t pgrp = getpgid(0);

  if (sandbox_argc == 2 && strcmp(sandbox_argv[1], "--help") == 0) {
    print_help();
    return 0;
  }

  const char *uid_arg = NULL, *gid_arg = NULL;
  int cmd_idx = parse_args(sandbox_argc, sandbox_argv, &uid_arg, &gid_arg);
  sandbox_argv += cmd_idx;
  sandbox_argc -= cmd_idx;
  uid_t dst_uid = uid_arg ? parse_id(uid_arg, "uid") : 0;
  gid_t dst_gid = gid_arg ? parse_id(gid_arg, "gid") : 0;

  if (verbose) {
    fprintf(stderr, "verbose sandbox enabled (running in %sprivileged container mode)\n",
            execution_mode == UNPRIVILEGED_CONTAINER_MODE ? "un" : "");
  }

  // In privileged mode, the sandbox runs as the user who called sudo.  Nested sandboxes
  // must not see these.
  uid_t uid = getuid();
  gid_t gid = getgid();
  const char *sudo_uid = getenv("SUDO_UID"), *sudo_gid = getenv("SUDO_GID");
  if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
    if (sudo_uid != NULL) {
      uid = parse_id(sudo_uid, "SUDO_UID");
    }
    if (sudo_gid != NULL) {
      gid = parse_id(sudo_gid, "SUDO_GID");
    }
  }
  unsetenv("SUDO_UID");
  unsetenv("SUDO_GID");

  // overlayfs doesn't support an upper layer that is mounted twice, so only one sandbox
  // at a time may use a persist directory.  The lock is held by the launcher's processes
  // and the sandbox's init, which outlive the sandbox's mounts, but not by the command:
  // the fd is close-on-exec.
  if (persist_dir != NULL) {
    mkpath(persist_dir);
    int lock_fd = open(persist_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    check(lock_fd != -1);
    if (0 != flock(lock_fd, LOCK_EX | LOCK_NB)) {
      check(errno == EWOULDBLOCK);
      fprintf(stderr, "ERROR: The persist directory '%s' is in use by another sandbox\n", persist_dir);
      return EXIT_SANDBOX_FAILED;
    }
  }

  // If we're running in one of the container modes, we're going to syscall() ourselves a
  // new, cloned process that is in a container process. We will use a pipe for synchronization.
  // The regular SIGSTOP method does not work because container-inits don't receive STOP or KILL
  // signals from within their own pid namespace.  The pipes are close-on-exec, so that
  // the sandboxed command cannot write a fake exit status to them.
  int child_pipe[2], parent_pipe[2];
  check(0 == pipe2(child_pipe, O_CLOEXEC));
  check(0 == pipe2(parent_pipe, O_CLOEXEC));

  if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
    // Mount everything as real root, in a mount namespace of our own.  The cgroup
    // namespace is new as well, so that the cgroup view is rooted at our cgroup, as it is
    // when mounted from within the sandbox's.
    check(0 == unshare(CLONE_NEWNS | CLONE_NEWCGROUP));
    mount_the_world(uid, gid);
    drop_supplementary_groups();
  }

  // We want to request a new PID space, a new mount space, a new user space, and
  // private hostname, IPC and cgroup namespaces.
  int clone_flags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUSER | CLONE_NEWUTS | CLONE_NEWIPC |
                    CLONE_NEWCGROUP | SIGCHLD;
  if ((child_pid = syscall(SYS_clone, clone_flags, 0, 0, 0, 0)) == 0) {
    // If we're in here, we have become the "child" process, within the container.

    // Get rid of the ends of the synchronization pipe that I'm not going to use
    close(child_pipe[1]);
    close(parent_pipe[0]);

    die_with_launcher(parent_pipe[1]);

    // N.B: Capabilities in the original user namespaces are now dropped
    // The kernel may have decided to reset our dumpability, because of
    // the privilege change. However, the parent needs to access our /proc
    // entries (undumpable processes have /proc/%pid owned by root) in order
    // to configure the sandbox, so reset dumpability.
    prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);

    // Tell the parent we're ready, and wait until it signals that it's done
    // setting up our PID/GID mapping in configure_user_namespace()
    check(1 == write(parent_pipe[1], "X", 1));
    char buff = 0;
    check(sizeof(char) == read(child_pipe[0], (void *)&buff, sizeof(char)));
    close(child_pipe[0]);

    if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
      // If we are in privileged container mode, let's go ahead and drop back
      // to the original calling user's UID and GID, which has been mapped to
      // the requested uid/gids (defaulting to zero) within this container.
      check(0 == setuid(dst_uid));
      check(0 == setgid(dst_gid));
      // Changing credentials disarmed the death signal.
      die_with_launcher(parent_pipe[1]);

      // The /proc mounted before we cloned is the host's PID namespace's.  The init's
      // own goes on top later, but the command may unmount that one, so cover the
      // host's with ours first.
      int root_fd = open_root(sandbox_root);
      mount_proc(root_fd);
      close(root_fd);

      // The rootfs was mounted before we entered this user namespace, so the kernel
      // locked it to its parent, and `pivot_root()` refuses a locked mount.  A
      // recursive bind of it made from in here is not locked itself.
      check(0 == mount(sandbox_root, sandbox_root, NULL, MS_BIND|MS_REC, NULL));
    } else {
      // If we're in unprivileged container mode, mount the world now that we
      // have supreme cosmic power.
      mount_the_world(dst_uid, dst_gid);
    }

    // Set the hostname, if that's been requested
    if (hostname != NULL) {
        check(sethostname(hostname, strlen(hostname)) == 0);
    }

    // Finally, we begin invocation of the target program.
    return sandbox_main(sandbox_argc, sandbox_argv, parent_pipe);
  }

  // If we're out here, we are still the "parent" process.  The Prestige lives on.

  // Check to make sure that the clone actually worked
  check(child_pid != -1);

  // We want to pass signals through to our child PID
  setup_signal_forwarding();

  // Get rid of the ends of the synchronization pipe that I'm not going to use.
  close(child_pipe[0]);
  close(parent_pipe[1]);

  // Wait until the child is ready to be configured.
  char buff = 0;
  check(sizeof(char) == read(parent_pipe[0], (void *)&buff, sizeof(char)));
  if (verbose) {
    fprintf(stderr, "Child Process PID is %d\n", child_pid);
  }

  // Configure user namespace for the child PID.
  configure_user_namespace(child_pid, uid, gid, dst_uid, dst_gid);

  // Signal to the child that it can now continue running.
  check(1 == write(child_pipe[1], "X", 1));

  // Wait until the child exits.
  check(child_pid == waitpid(child_pid, &status, 0));

  // Give back the terminal to the parent
  signal(SIGTTOU, SIG_IGN);
  tcsetpgrp(0, pgrp);

  // If the child does not exit cleanly, complain:
  if (!WIFEXITED(status) || (WIFEXITED(status) && WEXITSTATUS(status) != 0)) {
    if (verbose) {
      fprintf(stderr, "Child Sandbox exited uncleanly: ");
      if (WIFEXITED(status)) {
        fprintf(stderr, " (exit code: %d)\n", WEXITSTATUS(status));
      } else if (WIFSIGNALED(status)) {
        fprintf(stderr, " (signal: %d)\n", WTERMSIG(status));
      } else {
        fprintf(stderr, " (unknown)\n");
      }
    }

    // Don't bother failing later; just exit now.
    return EXIT_SANDBOX_FAILED;
  }

  // The sandboxed executable's exit value is reported via the pipe.  The child only
  // exits after the init that writes it, so the report is complete if it's there.
  uint32_t child_exit_code = -1;
  if (sizeof(uint32_t) != read(parent_pipe[0], (void *)&child_exit_code, sizeof(uint32_t))) {
    fputs("ERROR: Sandbox exited without reporting the exit status of the command\n", stderr);
    return EXIT_SANDBOX_FAILED;
  }

  // We encode signal death as 256 + signal
  if (child_exit_code >= 256) {
    int child_signal = child_exit_code - 256;
    if (verbose) {
      fprintf(stderr, "Child Process %d signaled %d\n", child_pid, child_signal);
    }

    // Kill ourselves with the same signal.  If that dumps core, the command already
    // did; being undumpable also stops a core_pattern pipe, which ignores RLIMIT_CORE.
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    signal(child_signal, SIG_DFL);
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, child_signal);
    sigprocmask(SIG_UNBLOCK, &mask, NULL);
    raise(child_signal);

    // We're still here if the signal doesn't terminate by default.
    return 128 + child_signal;
  } else {
    if (verbose) {
      fprintf(stderr, "Child Process %d exited with code %d\n", child_pid, child_exit_code);
    }
    return child_exit_code;
  }
}

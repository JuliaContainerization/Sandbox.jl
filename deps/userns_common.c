/* Copyright (c) 2023 JuliaHub Inc and contributors */
#define _GNU_SOURCE

#include "userns_common.h"

// verbose sets whether we're in verbose mode.
unsigned char verbose = 0;

/**** General Utilities ***/

/* Like assert, but don't go away with optimizations */
void _check(int ok, const char * file, int line) {
  if (!ok) {
    fprintf(stderr, "%s:%d, ABORTED (%d: %s)!\n", file, line, errno, strerror(errno));
    fflush(stdout);
    fflush(stderr);
    _exit(EXIT_SANDBOX_FAILED);
  }
}

/*
 * fork(2) without the C library's wrapper.  Our first child comes from a raw clone(2),
 * which the C library doesn't know about.  With glibc 2.17 (BinaryBuilder's static
 * builds), a fork() in that child and another in the grandchild deadlocks on malloc's
 * arena lock.  The children of a raw fork mustn't use what the C library caches about
 * the process either, such as its pid (getpid() before glibc 2.25).
 */
pid_t raw_fork(void) {
  return syscall(SYS_clone, SIGCHLD, 0, 0, 0, 0);
}

/* Opens /proc/%pid/%file, or /proc/self/%file for a `pid` of 0 */
int open_proc_file(pid_t pid, const char *file, int mode) {
  char path[PATH_MAX];
  int n = pid == 0 ? snprintf(path, sizeof(path), "/proc/self/%s", file)
                   : snprintf(path, sizeof(path), "/proc/%d/%s", pid, file);
  check(n >= 0 && n < sizeof(path));
  int fd = open(path, mode | O_CLOEXEC);
  check(fd != -1);
  return fd;
}

/* Make all directories up to the given directory name. */
void mkpath(const char * dir) {
  // If this directory already exists, back out.
  DIR * dir_obj = opendir(dir);
  if (dir_obj) {
    closedir(dir_obj);
    return;
  }
  errno = 0;

  // Otherwise, first make sure our parent exists.  Note that dirname()
  // clobbers its input, so we copy to a temporary variable first. >:|
  char dir_dirname[PATH_MAX];
  strncpy(dir_dirname, dir, PATH_MAX);
  mkpath(dirname(&dir_dirname[0]));

  // then create our directory
  int result = mkdir(dir, 0777);
  check((0 == result) || (errno == EEXIST));
}

/**** Paths inside the sandbox *****
 *
 * Mount destinations are looked up in the rootfs before we enter it.  The rootfs, and
 * the upper layer persisted from earlier runs, are under the control of the image and
 * of whatever ran in the sandbox before, so they may contain symlinks pointing anywhere.
 * Resolved by plain path from outside, an absolute symlink would lead the launcher to
 * create mount points on the host (as root, in privileged mode) and to mount over host
 * paths.  So destinations are resolved by descriptor, as if the rootfs were `/`, and
 * mount(2) is handed the resulting descriptor through /proc/self/fd.
 */

void fd_path(char *buf, int fd) {
  int n = snprintf(buf, FD_PATH_SIZE, "/proc/self/fd/%d", fd);
  check(n > 0 && n < FD_PATH_SIZE);
}

int open_root(const char *root_dir) {
  if (root_dir[0] == '\0') {
    root_dir = "/";
  }
  int fd = open(root_dir, O_PATH | O_DIRECTORY | O_CLOEXEC);
  check(fd != -1);
  return fd;
}

#define MAX_RESOLVE_DEPTH 256
#define MAX_RESOLVE_LINKS 40

/*
 * Opens `path` beneath the directory `root_fd` with O_PATH, resolving it as if `root_fd`
 * were the root directory: absolute symlinks start over from `root_fd`, and ".." does not
 * go above it.  If `create` is S_IFDIR or S_IFREG, missing components are created, as
 * directories except for the last one, which gets the type `create`.  Following a
 * dangling symlink creates its target, so that a destination like Ubuntu's
 * /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf can be mapped over.
 * Returns -1 with `errno` set on failure.
 *
 * openat2(RESOLVE_IN_ROOT) could resolve an existing path in one call, but it needs
 * Linux 5.6, and creating what is missing takes a walk like this one anyway.  Each step
 * is an openat(O_NOFOLLOW) relative to the directory before it, and symlinks are read and
 * resolved here, so the kernel never follows one (or a /proc magic link) for us.  ".."
 * goes back to the directory we came from, which is what RESOLVE_IN_ROOT does as well.
 */
int open_in_root(int root_fd, const char *path, mode_t create) {
  char buf[PATH_MAX], next[PATH_MAX], target[PATH_MAX];
  // The directories walked so far; the last one is where we are.
  int dirs[MAX_RESOLVE_DEPTH];
  int depth = 0, links = 0, fd = -1, saved_errno;
  struct stat st;

  if (strlen(path) >= sizeof(buf)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  strcpy(buf, path);
  char *rest = buf;
  for (;;) {
    while (*rest == '/') {
      rest++;
    }
    if (*rest == '\0') {
      break;
    }
    char *name = rest;
    rest = strchrnul(rest, '/');
    int slash = *rest == '/';
    if (slash) {
      *rest++ = '\0';
    }
    int last = rest[strspn(rest, "/")] == '\0';
    // As in any lookup, a trailing slash requires a directory.
    int dir_only = !last || slash;

    if (strcmp(name, ".") == 0) {
      continue;
    }
    if (strcmp(name, "..") == 0) {
      if (depth > 0) {
        close(dirs[--depth]);
      }
      continue;
    }

    int dir_fd = depth > 0 ? dirs[depth-1] : root_fd;
    fd = openat(dir_fd, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    if (fd == -1 && errno == ENOENT && create) {
      if (!dir_only && create == S_IFREG) {
        int new_fd = openat(dir_fd, name, O_RDONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            S_IRUSR | S_IRGRP | S_IROTH);
        if (new_fd == -1 && errno != EEXIST) {
          goto fail;
        }
        if (new_fd != -1) {
          close(new_fd);
        }
      } else if (mkdirat(dir_fd, name, 0777) != 0 && errno != EEXIST) {
        goto fail;
      }
      fd = openat(dir_fd, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
    }
    if (fd == -1 || fstat(fd, &st) != 0) {
      goto fail;
    }

    if (S_ISLNK(st.st_mode)) {
      ssize_t len = readlinkat(fd, "", target, sizeof(target) - 1);
      if (len == -1) {
        goto fail;
      }
      close(fd);
      fd = -1;
      if (++links > MAX_RESOLVE_LINKS) {
        errno = ELOOP;
        goto fail;
      }
      target[len] = '\0';
      int n = snprintf(next, sizeof(next), "%s%s%s", target, slash ? "/" : "", rest);
      if (n < 0 || n >= sizeof(next)) {
        errno = ENAMETOOLONG;
        goto fail;
      }
      if (target[0] == '/') {
        while (depth > 0) {
          close(dirs[--depth]);
        }
      }
      strcpy(buf, next);
      rest = buf;
      continue;
    }

    if (dir_only && !S_ISDIR(st.st_mode)) {
      errno = ENOTDIR;
      goto fail;
    }
    if (depth == MAX_RESOLVE_DEPTH) {
      errno = ENAMETOOLONG;
      goto fail;
    }
    dirs[depth++] = fd;
    fd = -1;
  }

  if (depth > 0) {
    fd = dirs[--depth];
  } else {
    fd = fcntl(root_fd, F_DUPFD_CLOEXEC, 0);
  }
  while (depth > 0) {
    close(dirs[--depth]);
  }
  return fd;

fail:
  saved_errno = errno;
  if (fd != -1) {
    close(fd);
  }
  while (depth > 0) {
    close(dirs[--depth]);
  }
  errno = saved_errno;
  return -1;
}

/* Like `open_in_root()`, but reports what went wrong and exits on failure. */
int open_in_root_or_die(int root_fd, const char *path, mode_t create) {
  int fd = open_in_root(root_fd, path, create);
  if (fd == -1) {
    fprintf(stderr, "ERROR: Failed to %s '%s' in the sandbox: %s (errno %d)\n",
            create ? "create" : "open", path, strerror(errno), errno);
    _exit(EXIT_SANDBOX_FAILED);
  }
  return fd;
}


/**** Signal handling *****
 *
 * We will support "passing through" signals to the child process transparently,
 * for a predefined set of signals, which we set up here.  The signal chain will
 * pass from the 'outer' sandbox process (e.g. the parent of `clone()`) to the
 * 'inner' sandbox process (e.g. the parent of `fork()`), and finally to the
 * actual target process (e.g. the child of `fork()`).
 */

pid_t child_pid;
static void signal_passthrough(int sig, siginfo_t *info, void *context) {
  int saved_errno = errno;
  // The terminal signals its whole foreground process group, which the sandboxed
  // processes share with us unless the command left it.  Don't deliver those twice.
  if (!(info->si_code == SI_KERNEL && getpgid(child_pid) == getpgrp())) {
    kill(child_pid, sig);
  }
  errno = saved_errno;
}

// The list of signals that we will forward to our child process.  Job control signals
// are not among them: the kernel stops and continues the whole process group, and a
// handler for them would keep us from stopping along with the sandbox.
int forwarded_signals[] = {
  SIGHUP,
  SIGINT,
  SIGQUIT,
  SIGUSR1,
  SIGUSR2,
  SIGTERM,
  SIGWINCH
};

void setup_signal_forwarding() {
  struct sigaction sa = {0};
  sa.sa_sigaction = signal_passthrough;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  for (int idx=0; idx<sizeof(forwarded_signals)/sizeof(int); idx++) {
    check(0 == sigaction(forwarded_signals[idx], &sa, NULL));
  }
}

/**** User namespaces *****
 *
 * For a general overview on user namespaces, see the corresponding manual page
 * user_namespaces(7). In general, user namespaces allow unprivileged users to
 * run privileged executables, by rewriting uids inside the namespaces (and
 * in particular, a user can be root inside the namespace, but not outside),
 * with the kernel still enforcing access protection as if the user was
 * unprivilged (to all files and resources not created exclusively within the
 * namespace). Absent kernel bugs, this provides relatively strong protections
 * against misconfiguration (because no true privilege is ever bestowed upon
 * the sandbox). It should be noted however, that there were such kernel bugs
 * as recently as Feb 2016.  These were sneaky privilege escalation bugs,
 * rather unimportant to the use case of BinaryBuilder, but a recent and fully
 * patched kernel should be considered essential for any security-sensitive
 * work done on top of this infrastructure).
 */
void configure_user_namespace(pid_t pid, uid_t src_uid, gid_t src_gid,
                              uid_t dst_uid, gid_t dst_gid) {
  int nbytes = 0;

  if (verbose) {
    fprintf(stderr, "--> Mapping %d:%d to %d:%d within container namespace\n",
            src_uid, src_gid, dst_uid, dst_gid);
  }

  // Setup uid map
  int uidmap_fd = open_proc_file(pid, "uid_map", O_WRONLY);
  check(uidmap_fd != -1);
  char uidmap[100];
  nbytes = snprintf(uidmap, sizeof(uidmap), "%d\t%d\t1\n", dst_uid, src_uid);
  check(nbytes > 0 && nbytes <= sizeof(uidmap));
  check(write(uidmap_fd, uidmap, nbytes) == nbytes);
  close(uidmap_fd);

  // Deny setgroups
  int setgroups_fd = open_proc_file(pid, "setgroups", O_WRONLY);
  char deny[] = "deny";
  check(write(setgroups_fd, deny, sizeof(deny)) == sizeof(deny));
  close(setgroups_fd);

  // Setup gid map
  int gidmap_fd = open_proc_file(pid, "gid_map", O_WRONLY);
  check(gidmap_fd != -1);
  char gidmap[100];
  nbytes = snprintf(gidmap, sizeof(gidmap), "%d\t%d\t1", dst_gid, src_gid);
  check(nbytes > 0 && nbytes <= sizeof(gidmap));
  check(write(gidmap_fd, gidmap, nbytes) == nbytes);
  close(gidmap_fd);
}


/*
 * Mount an overlayfs from `src` onto `dest`, anchoring the changes made to the overlayfs
 * within the folders `work_dir`/upper and `work_dir`/work.  Note that the common case of
 * `src` == `dest` signifies that we "shadow" the original source location and will simply
 * discard any changes made to it when the overlayfs disappears.  This is how we protect our
 * rootfs and shards when mounting from a local filesystem, as well as how we convert a
 * read-only rootfs and shards to a read-write system when mounting from squashfs images.
 * `flags` are the mount flags for mount(2).
 */
uint8_t mount_overlay(const char * src, const char * dest, const char * bname,
                      const char * work_dir, uint8_t userxattr, unsigned long flags) {
  char upper[PATH_MAX], work[PATH_MAX], opts[3*PATH_MAX+40];

  // Construct the location of our upper and work directories
  snprintf(upper, sizeof(upper), "%s/upper/%s", work_dir, bname);
  snprintf(work, sizeof(work), "%s/work/%s", work_dir, bname);

  // If `src` or `dest` is "", we actually want it to be "/", so adapt here because
  // this is the only place in the code base where we actually need the slash at the
  // end of the directory name.
  if (src[0] == '\0') {
    src = "/";
  }
  if (dest[0] == '\0') {
    dest = "/";
  }

  if (verbose) {
    fprintf(stderr, "--> Mounting overlay of %s at %s (modifications in %s, workspace in %s, userxattr: %d)\n", src, dest, upper, work, userxattr);
  }

  // Make the upper and work directories
  mkpath(upper);
  mkpath(work);

  // Construct the opts, mount the overlay
  const char * userxattr_opt = "";
  if (userxattr) {
    userxattr_opt = ",userxattr";
  }
  // Without the index, which the kernel may enable by default: with it, the upper layer
  // only mounts again over the lower layer it was made with, while a read-only overlay
  // of another directory is how the changes made through an overlay are looked at.
  snprintf(opts, sizeof(opts), "lowerdir=%s,upperdir=%s,workdir=%s,index=off%s", src, upper, work, userxattr_opt);
  
  // Not `check()`: the caller may try again with other options.
  if (0 != mount("overlay", dest, "overlay", flags, opts)) {
    int saved_errno = errno;
    if (verbose) {
      fprintf(stderr, "----> mount(\"overlay\", \"%s\", \"overlay\", %lu, \"%s\") failed: %d (%s)\n", dest, flags, opts, errno, strerror(errno));
    }
    errno = saved_errno;
    return FALSE;
  }

  return TRUE;
}

/**** Restricted mounts *****
 *
 * A bind mount made read-only (or nodev, nosuid) by MS_REMOUNT is so on its own; the
 * mounts below it that came along with MS_REC are not.  mount_setattr(2) (Linux 5.12)
 * changes a whole tree at once.  On older kernels, each mount of the tree is remounted
 * by itself, as listed in /proc/self/mountinfo.
 */

#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#ifndef MS_NOSYMFOLLOW
#define MS_NOSYMFOLLOW 256
#endif
#define SANDBOX_MOUNT_ATTR_RDONLY 0x00000001
#define SANDBOX_MOUNT_ATTR_NOSUID 0x00000002
#define SANDBOX_MOUNT_ATTR_NODEV 0x00000004

struct sandbox_mount_attr {
  uint64_t attr_set;
  uint64_t attr_clr;
  uint64_t propagation;
  uint64_t userns_fd;
};

/* The mount flags, as for MS_REMOUNT, in the per-mount options of /proc/self/mountinfo
   (which are split up in place). */
static unsigned long parse_mount_flags(char *options) {
  unsigned long flags = 0;
  int atime = 0;
  for (char *save, *opt = strtok_r(options, ",", &save); opt != NULL; opt = strtok_r(NULL, ",", &save)) {
    if (strcmp(opt, "ro") == 0)
      flags |= MS_RDONLY;
    else if (strcmp(opt, "nosuid") == 0)
      flags |= MS_NOSUID;
    else if (strcmp(opt, "nodev") == 0)
      flags |= MS_NODEV;
    else if (strcmp(opt, "noexec") == 0)
      flags |= MS_NOEXEC;
    else if (strcmp(opt, "nodiratime") == 0)
      flags |= MS_NODIRATIME;
    else if (strcmp(opt, "noatime") == 0)
      flags |= MS_NOATIME, atime = 1;
    else if (strcmp(opt, "relatime") == 0)
      flags |= MS_RELATIME, atime = 1;
    else if (strcmp(opt, "nosymfollow") == 0)
      flags |= MS_NOSYMFOLLOW;
  }
  // mountinfo shows neither for strictatime, which the kernel would otherwise take
  // to mean relatime.
  if (!atime)
    flags |= MS_STRICTATIME;
  return flags;
}

/* Undoes the octal escapes (\040 etc.) of a mountinfo path, in place. */
static void unescape_mountinfo(char *s) {
  char *out = s;
  for (; *s; s++) {
    if (s[0] == '\\' && s[1] >= '0' && s[1] <= '3' && s[2] >= '0' && s[2] <= '7' && s[3] >= '0' && s[3] <= '7') {
      *out++ = (char)((s[1] - '0') << 6 | (s[2] - '0') << 3 | (s[3] - '0'));
      s += 3;
    } else {
      *out++ = *s;
    }
  }
  *out = '\0';
}

static int mount_id_of(int fd) {
  char path[64], line[256];
  snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", fd);
  FILE *f = fopen(path, "re");
  check(f != NULL);
  int id = -1;
  while (fgets(line, sizeof(line), f)) {
    if (sscanf(line, "mnt_id: %d", &id) == 1)
      break;
  }
  fclose(f);
  check(id != -1);
  return id;
}

struct mountinfo_entry {
  int id, parent, in_tree;
  char *mount_point;
  unsigned long flags;
};

/*
 * Remounts with `flags` added, by themselves, the mount at `fd` and every mount below it
 * in /proc/self/mountinfo.  The submounts are looked up from `fd`, by their path below it.
 */
static void restrict_mount_fallback(int fd, const char *dest, unsigned long flags) {
  struct mountinfo_entry *entries = NULL;
  size_t n_entries = 0, cap = 0;
  char *line = NULL;
  size_t line_cap = 0;
  int target_id = mount_id_of(fd);

  FILE *f = fopen("/proc/self/mountinfo", "re");
  check(f != NULL);
  while (getline(&line, &line_cap, f) != -1) {
    // id parent major:minor root mount_point options ..., with spaces in paths escaped
    char *fields[6], *save = NULL;
    int n = 0;
    for (char *tok = strtok_r(line, " \n", &save); tok != NULL && n < 6; tok = strtok_r(NULL, " \n", &save)) {
      fields[n++] = tok;
    }
    check(n == 6);
    if (n_entries == cap) {
      cap = cap ? 2 * cap : 64;
      entries = realloc(entries, cap * sizeof(*entries));
      check(entries != NULL);
    }
    int id = atoi(fields[0]);
    unescape_mountinfo(fields[4]);
    entries[n_entries++] = (struct mountinfo_entry) {
      .id = id, .parent = atoi(fields[1]), .in_tree = id == target_id,
      .mount_point = strdup(fields[4]), .flags = parse_mount_flags(fields[5]),
    };
    check(entries[n_entries-1].mount_point != NULL);
  }
  check(!ferror(f));
  free(line);
  fclose(f);

  // Mark the tree below the target.  mountinfo usually lists parents first, but
  // not always (e.g. after MS_MOVE), so repeat until nothing changes.
  const char *root = NULL;
  for (int changed = 1; changed; ) {
    changed = 0;
    for (size_t i = 0; i < n_entries; i++) {
      if (entries[i].id == target_id)
        root = entries[i].mount_point;
      if (entries[i].in_tree)
        continue;
      for (size_t j = 0; j < n_entries; j++) {
        if (entries[j].in_tree && entries[j].id == entries[i].parent) {
          entries[i].in_tree = changed = 1;
          break;
        }
      }
    }
  }
  check(root != NULL);
  size_t root_len = strcmp(root, "/") == 0 ? 0 : strlen(root);

  for (size_t i = 0; i < n_entries; i++) {
    struct mountinfo_entry *e = &entries[i];
    if (!e->in_tree)
      continue;
    char path[FD_PATH_SIZE];
    int sub_fd;
    if (e->id == target_id) {
      sub_fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    } else {
      check(strncmp(e->mount_point, root, root_len) == 0 &&
            (e->mount_point[root_len] == '/' || e->mount_point[root_len] == '\0'));
      sub_fd = open_in_root(fd, e->mount_point + root_len, 0);
      if (sub_fd == -1) {
        // Below something we cannot look into, so out of the sandbox's reach as well.
        check(errno == EACCES);
        continue;
      }
      if (mount_id_of(sub_fd) != e->id) {
        // Covered by another mount of the tree, which leaves no way to reach it.
        close(sub_fd);
        continue;
      }
    }
    fd_path(path, sub_fd);
    if (verbose) {
      fprintf(stderr, "----> Remounting %s\n", e->mount_point);
    }
    // Only add flags: the kernel refuses to clear the flags it locked on mounts that
    // came from a more privileged mount namespace.
    if (0 != mount(NULL, path, NULL, MS_BIND|MS_REMOUNT|flags|e->flags, NULL)) {
      fprintf(stderr, "ERROR: Failed to restrict %s (%s): %s (errno %d)\n",
              dest, e->mount_point, strerror(errno), errno);
      _exit(EXIT_SANDBOX_FAILED);
    }
    close(sub_fd);
  }

  for (size_t i = 0; i < n_entries; i++)
    free(entries[i].mount_point);
  free(entries);
}

/*
 * Adds `flags` (MS_RDONLY, MS_NOSUID and MS_NODEV) to the mount at `fd` and all mounts
 * below it.  `dest` names it in messages.  SANDBOX_MOUNT_SETATTR=0 skips
 * mount_setattr(2), so that the tests can exercise the fallback for older kernels.
 */
void restrict_mount(int fd, const char *dest, unsigned long flags) {
  const char *use_setattr = getenv("SANDBOX_MOUNT_SETATTR");
  if (use_setattr == NULL || strcmp(use_setattr, "0") != 0) {
    struct sandbox_mount_attr attr = {
      .attr_set = (flags & MS_RDONLY ? SANDBOX_MOUNT_ATTR_RDONLY : 0) |
                  (flags & MS_NOSUID ? SANDBOX_MOUNT_ATTR_NOSUID : 0) |
                  (flags & MS_NODEV ? SANDBOX_MOUNT_ATTR_NODEV : 0),
    };
    if (0 == syscall(SYS_mount_setattr, fd, "", AT_EMPTY_PATH | AT_RECURSIVE, &attr, sizeof(attr)))
      return;
    if (errno != ENOSYS) {
      fprintf(stderr, "ERROR: Failed to restrict %s: %s (errno %d)\n",
              dest, strerror(errno), errno);
      _exit(EXIT_SANDBOX_FAILED);
    }
  }
  restrict_mount_fallback(fd, dest, flags);
}

/*
 * Refuses a destination such as `/a/..`, or a symlink to `/`, which would cover the root
 * itself: the rest of the setup (going through `root_fd`) would no longer see it.
 */
void check_not_root(int root_fd, int fd, const char *dest) {
  struct stat dest_stat, root_stat;
  check(0 == fstat(fd, &dest_stat) && 0 == fstat(root_fd, &root_stat));
  if (dest_stat.st_dev == root_stat.st_dev && dest_stat.st_ino == root_stat.st_ino) {
    fprintf(stderr, "ERROR: Failed to mount at '%s': it is the root of the sandbox\n", dest);
    _exit(EXIT_SANDBOX_FAILED);
  }
}

/*
 * Refuses `fd` in the procfs, which the sandbox's init mounts again over the operations,
 * as `add_op()` does for destinations that say /proc, for those that only get there
 * through `..` or symlinks.
 */
void check_not_proc(int fd, const char *dest) {
  struct statfs fs;
  check(0 == fstatfs(fd, &fs));
  if (fs.f_type == PROC_SUPER_MAGIC) {
    fprintf(stderr, "ERROR: Failed to mount at '%s': it is in /proc, which the sandbox mounts itself\n", dest);
    _exit(EXIT_SANDBOX_FAILED);
  }
}

/*
 * Bind-mounts `src_fd` (the host path `src`) at `dest` in the rootfs `root_fd`, creating
 * the mount point as a directory or file to match it, and adds `flags` as for
 * `restrict_mount()`.
 */
void bind_mount(int root_fd, int src_fd, const char *src, const char *dest, unsigned long flags) {
  char src_path[FD_PATH_SIZE], dest_path[FD_PATH_SIZE];

  if (verbose) {
    fprintf(stderr, "--> Bind-mounting %s over %s (%s%s%s)\n", src, dest,
            flags & MS_RDONLY ? "read-only" : "read-write",
            flags & MS_NOSUID ? ", nosuid" : "", flags & MS_NODEV ? ", nodev" : "");
  }

  struct stat src_stat;
  check(0 == fstat(src_fd, &src_stat));
  fd_path(src_path, src_fd);

  int dest_fd = open_in_root_or_die(root_fd, dest, S_ISDIR(src_stat.st_mode) ? S_IFDIR : S_IFREG);
  check_not_root(root_fd, dest_fd, dest);
  check_not_proc(dest_fd, dest);
  fd_path(dest_path, dest_fd);

  // Recursively, so that a bind of a tree with mounts below it shows them as well.
  check(0 == mount(src_path, dest_path, "", MS_BIND|MS_REC, NULL));
  close(dest_fd);

  if (flags) {
    // The new mount is on top of the mount point, so look it up again.
    dest_fd = open_in_root_or_die(root_fd, dest, 0);
    restrict_mount(dest_fd, dest, flags);
    close(dest_fd);
  }
}

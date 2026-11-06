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

/* Opens /proc/%pid/%file */
int open_proc_file(pid_t pid, const char *file, int mode) {
  char path[PATH_MAX];
  int n = snprintf(path, sizeof(path), "/proc/%d/%s", pid, file);
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

int isdir(const char * path) {
  struct stat path_stat;
  int result = stat(path, &path_stat);

  // Silently ignore calling `isdir()` on a non-existant path
  check((0 == result) || (errno == ENOENT) || (errno == ENOTDIR));
  return S_ISDIR(path_stat.st_mode);
}

int unlink_callback(const char *fpath, const struct stat * a, int b, struct FTW * c) {
  int rv = remove(fpath);
  if (rv) {
    fprintf(stderr, "remove failed: %d (%s)\n", errno, strerror(errno));
  }
  return rv;
}

void rmrf(const char * path) {
  nftw(path, unlink_callback, 64, FTW_DEPTH | FTW_PHYS);
}

// One-byte-at-a-time hash based on Murmur's mix
// Source: https://github.com/aappleby/smhasher/blob/master/src/Hashes.cpp
// X-ref: https://stackoverflow.com/a/69812981/230778
uint32_t string_hash(const char *str, uint32_t h) {
    for (; *str; ++str) {
        h ^= *str;
        h *= 0x5bd1e995;
        h ^= h >> 15;
    }
    return h;
}

// Given a path, return its basename plus a hash representing the rest of the path
void hashed_basename(char *output, const char *path) {
  uint32_t hash = string_hash(path, 0x5f3759df);
  sprintf(output, "%s-%x", basename((char *)path), hash);
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
 */
uint8_t mount_overlay(const char * src, const char * dest, const char * bname,
                      const char * work_dir, uint8_t userxattr) {
  char upper[PATH_MAX], work[PATH_MAX], opts[3*PATH_MAX+28];

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
  snprintf(opts, sizeof(opts), "lowerdir=%s,upperdir=%s,workdir=%s%s", src, upper, work, userxattr_opt);
  
  // We don't use `check()` here, because we want to be able to handle this in `userns_overlay_probe()`
  if (0 != mount("overlay", dest, "overlay", 0, opts)) {
    if (verbose) {
      fprintf(stderr, "----> mount(\"overlay\", \"%s\", \"overlay\", 0, \"%s\") failed: %d (%s)\n", dest, opts, errno, strerror(errno));
    }
    return FALSE;
  }

  return TRUE;
}

void mount_procfs(const char * root_dir, uid_t uid, gid_t gid) {
  char path[FD_PATH_SIZE];

  int root_fd = open_root(root_dir);
  int fd = open_in_root_or_die(root_fd, "/proc", 0);
  fd_path(path, fd);
  if (verbose) {
    fprintf(stderr, "--> Mounting procfs at %s/proc\n", root_dir);
  }
  check(0 == mount("proc", path, "proc", 0, ""));
  close(fd);

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox.  We allow this to fail, as
  // sometimes we're trying to chown() something we don't own.
  fd = open_in_root_or_die(root_fd, "/proc", 0);
  int ignored = fchownat(fd, "", uid, gid, AT_EMPTY_PATH);
  close(fd);
  close(root_fd);
}

/*
 * Bind-mounts the host path `src` (or a /proc/self/fd path) at `dest` in the rootfs
 * `root_fd`, creating the mount point as a directory or file to match `src`.
 */
void bind_mount(int root_fd, const char *src, const char *dest, char read_only) {
  char src_path[FD_PATH_SIZE], dest_path[FD_PATH_SIZE];

  if (verbose) {
    fprintf(stderr, "--> Bind-mounting %s over %s (%s)\n", src, dest,
            read_only ? "read-only" : "read-write");
  }

  int src_fd = open(src, O_PATH | O_CLOEXEC);
  if (src_fd == -1) {
    fprintf(stderr, "ERROR: Failed to mount '%s' to '%s': %s (errno %d)\n",
            src, dest, strerror(errno), errno);
    fprintf(stderr, "  Please ensure that '%s' exists and is accessible.\n", src);
    _exit(EXIT_SANDBOX_FAILED);
  }
  struct stat src_stat;
  check(0 == fstat(src_fd, &src_stat));
  fd_path(src_path, src_fd);

  int dest_fd = open_in_root_or_die(root_fd, dest, S_ISDIR(src_stat.st_mode) ? S_IFDIR : S_IFREG);
  fd_path(dest_path, dest_fd);

  // A destination such as `/a/..`, or a symlink to `/`, would cover the root itself,
  // which the rest of the setup (going through `root_fd`) would no longer see.
  struct stat dest_stat, root_stat;
  check(0 == fstat(dest_fd, &dest_stat) && 0 == fstat(root_fd, &root_stat));
  if (dest_stat.st_dev == root_stat.st_dev && dest_stat.st_ino == root_stat.st_ino) {
    fprintf(stderr, "ERROR: Failed to mount '%s' to '%s': it is the root of the sandbox\n", src, dest);
    _exit(EXIT_SANDBOX_FAILED);
  }

  // We don't expect workspaces to have any submounts in normal operation.
  // However, for runshell(), workspace could be an arbitrary directory,
  // including one with sub-mounts, so allow that situation with MS_REC.
  check(0 == mount(src_path, dest_path, "", MS_BIND|MS_REC, NULL));
  close(dest_fd);
  close(src_fd);

  // remount to read-only. this requires a separate remount:
  // https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git/commit/?id=9ac77b8a78452eab0612523d27fee52159f5016a
  // during such a remount, we're not allowed to clear locked mount flags:
  // https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9566d6742852c527bf5af38af5cbb878dad75705
  if (read_only) {
    // we cannot apply locked mount flags blindly, because they change behaviour of the
    // mount (e.g. noexec), so figure out which ones we need by looking at mtab.
    struct mntent *mnt = NULL;
    FILE * mtab = setmntent("/proc/self/mounts", "r");
    check(mtab != NULL);
    while (mnt = getmntent(mtab)) {
        struct stat dev_stat;
        // It's possible that we try to stat() something that we're
        // not allowed to look at; if that occurs, skip it, hoping
        // that it's not the mount we're actually interested in.
        if (stat(mnt->mnt_dir, &dev_stat) == 0 &&
            dev_stat.st_dev == src_stat.st_dev)
            break;

        // Don't let a non-matching `mnt` leak through, in the event
        // that we never find the device the mount belongs to.
        mnt = NULL;
    }
    endmntent(mtab);

    // This will fail if we never found the matching `mnt`.
    check(mnt != NULL);

    int locked_flags = 0;
    char *mnt_opt;
    mnt_opt = strtok(mnt->mnt_opts, ",");
    while (mnt_opt != NULL) {
        if (strcmp(mnt_opt, "nodev") == 0)
            locked_flags |= MS_NODEV;
        else if (strcmp(mnt_opt, "nosuid") == 0)
            locked_flags |= MS_NOSUID;
        else if (strcmp(mnt_opt, "noexec") == 0)
            locked_flags |= MS_NOEXEC;
        else if (strcmp(mnt_opt, "noatime") == 0)
            locked_flags |= MS_NOATIME;
        else if (strcmp(mnt_opt, "nodiratime") == 0)
            locked_flags |= MS_NODIRATIME;
        else if (strcmp(mnt_opt, "relatime") == 0)
            locked_flags |= MS_RELATIME;
        mnt_opt = strtok(NULL, ",");
    }

    // The new mount is on top of the mount point, so look it up again.
    dest_fd = open_in_root_or_die(root_fd, dest, 0);
    fd_path(dest_path, dest_fd);
    check(0 == mount(NULL, dest_path, "", MS_BIND|MS_REMOUNT|MS_RDONLY|locked_flags, NULL));
    close(dest_fd);
  }
}

void bind_host_node(int root_fd, const char *name, char read_only) {
  if (access(name, F_OK) == 0) {
    bind_mount(root_fd, name, name, read_only);
  }
}

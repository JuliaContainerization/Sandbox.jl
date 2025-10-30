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
    _exit(1);
  }
}

/* Opens /proc/%pid/%file */
int open_proc_file(pid_t pid, const char *file, int mode) {
  char path[PATH_MAX];
  int n = snprintf(path, sizeof(path), "/proc/%d/%s", pid, file);
  check(n >= 0 && n < sizeof(path));
  int fd = open(path, mode);
  check(fd != -1);
  return fd;
}

/* `touch` a file; create it if it doesn't already exist. */
void touch(const char * path) {
  int fd = open(path, O_RDONLY | O_CREAT, S_IRUSR | S_IRGRP | S_IROTH);
  // Ignore EISDIR as sometimes we try to `touch()` a directory
  if (fd == -1 && errno != EISDIR) {
    check(fd != -1);
  }
  close(fd);
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

int islink(const char * path) {
  struct stat path_stat;
  int result = stat(path, &path_stat);

  // Silently ignore calling `islink()` on a non-existant path
  check((0 == result) || (errno == ENOENT) || (errno == ENOTDIR));
  return S_ISLNK(path_stat.st_mode);
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


/**** Signal handling *****
 *
 * We will support "passing through" signals to the child process transparently,
 * for a predefined set of signals, which we set up here.  The signal chain will
 * pass from the 'outer' sandbox process (e.g. the parent of `clone()`) to the
 * 'inner' sandbox process (e.g. the parent of `fork()`), and finally to the
 * actual target process (e.g. the child of `fork()`).
 */

pid_t child_pid;
void signal_passthrough(int sig) {
  kill(child_pid, sig);
}

// The list of signals that we will forward to our child process
int forwarded_signals[] = {
  SIGHUP,
  SIGINT,
  SIGQUIT,
  SIGUSR1,
  SIGUSR2,
  SIGTERM,
  SIGCONT,
  SIGSTOP,
  SIGTSTP,
  SIGTTIN,
  SIGTTOU,
  SIGWINCH
};

void setup_signal_forwarding() {
  for (int idx=0; idx<sizeof(forwarded_signals)/sizeof(int); idx++) {
    signal(forwarded_signals[idx], signal_passthrough);
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
  char path[PATH_MAX];

  // Mount procfs at <root_dir>/proc
  snprintf(path, sizeof(path), "%s/proc", root_dir);
  if (verbose) {
    fprintf(stderr, "--> Mounting procfs at %s\n", path);
  }
  // Attempt to unmount a previous /proc if it exists
  check(0 == mount("proc", path, "proc", 0, ""));

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox.  We allow this to fail, as
  // sometimes we're trying to chown() something we don't own.
  int ignored = chown(path, uid, gid);
}

void bind_mount(const char *src, const char *dest, char read_only) {
  // If `src` is a symlink, this bindmount may run into issues, so we collapse
  // `src` via `realpath()` to ensure that we get a non-symlink.
  char resolved_src[PATH_MAX] = {0};
  if (islink(src)) {
    if (NULL == realpath(src, resolved_src)) {
      if (verbose) {
        fprintf(stderr, "WARNING: Unable to resolve %s ([%d] %s)\n", src, errno, strerror(errno));
      }
    }
  }

  if (resolved_src[0] == '\0') {
    strncpy(resolved_src, src, PATH_MAX);
  }

  if (verbose) {
    if (read_only) {
      fprintf(stderr, "--> Bind-mounting %s over %s (read-only)\n", resolved_src, dest);
    } else {
      fprintf(stderr, "--> Bind-mounting %s over %s (read-write)\n", resolved_src, dest);
    }
  }

  // If we're mounting in a directory, create the mountpoint as a directory,
  // otherwise as a file.  Note that if `src` does not exist, we'll create a
  // file here, then error out on the `mount()` call.
  if (isdir(resolved_src)) {
    mkpath(dest);
  } else {
    touch(dest);
  }

  // We don't expect workspaces to have any submounts in normal operation.
  // However, for runshell(), workspace could be an arbitrary directory,
  // including one with sub-mounts, so allow that situation with MS_REC.
  int mount_result = mount(resolved_src, dest, "", MS_BIND|MS_REC, NULL);
  if (mount_result != 0 && errno == ENOENT) {
    // Provide a more descriptive error for missing paths
    fprintf(stderr, "ERROR: Failed to mount '%s' to '%s': %s (errno %d)\n",
            resolved_src, dest, strerror(errno), errno);
    fprintf(stderr, "  Please ensure that '%s' exists and is accessible.\n", resolved_src);
    _exit(1);
  }
  check(mount_result == 0);

  // remount to read-only. this requires a separate remount:
  // https://git.kernel.org/pub/scm/utils/util-linux/util-linux.git/commit/?id=9ac77b8a78452eab0612523d27fee52159f5016a
  // during such a remount, we're not allowed to clear locked mount flags:
  // https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=9566d6742852c527bf5af38af5cbb878dad75705
  if (read_only) {
    // we cannot apply locked mount flags blindly, because they change behaviour of the
    // mount (e.g. noexec), so figure out which ones we need by looking at mtab.
    struct stat src_stat;
    stat(resolved_src, &src_stat);

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
    check(0 == mount(resolved_src, dest, "", MS_BIND|MS_REMOUNT|MS_RDONLY|locked_flags, NULL));
  }
}

void bind_host_node(const char *root_dir, const char *name, char read_only) {
  char path[PATH_MAX];
  if (access(name, F_OK) == 0) {
    snprintf(path, sizeof(path), "%s/%s", root_dir, name);
    bind_mount(name, path, read_only);
  }
}

/* Copyright (c) 2023 Julia Computing Inc and contributors */
#define _GNU_SOURCE

/*
  sandbox.c - Sandbox execution platform

This file serves as the entrypoint into our sandboxed/virtualized execution environment for
BinaryBuilder.jl; it has two execution modes:

  1) Unprivileged container mode.
  2) Privileged container mode.

The two modes do similar things, but in different orders and with different privileges. Eventually,
all modes seek the same result; to run a user program with the base root fs and any other shards
requested by the user within the BinaryBuilder.jl execution environment:

* Unprivileged container mode is the "normal" mode of execution; it attempts to use the native
kernel namespace abilities to setup its environment without ever needing to be `root`. It does this
by creating a user namespace, then using its root privileges within the namespace to mount the
necesary shards, `chroot`, etc... within the right places in the new mount namespace created within
the container.

* Privileged container mode is what happens when `sandbox` is invoked with EUID == 0.  In this
mode, the mounts and chroots and whatnot are performed _before_ creating a new user namespace.
This is used as a workaround for kernels that do not have the capabilities for creating mounts
within user namespaces.  Arch Linux is a great example of this.

To test this executable, compile it with:

    gcc -O2 -static -static-libgcc -std=c99 -o /tmp/sandbox ./userns_sandbox.c

Then run it, mounting in a rootfs with a workspace and no other read-only maps:

    mkdir -p /tmp/workspace
    /tmp/sandbox --verbose --rootfs $rootfs_dir --mount /tmp/workspace:/workspace --cd /workspace /bin/bash
*/

#include "userns_common.h"

// sandbox_root is the location of the rootfs on disk.  This is required.
char *sandbox_root = NULL;

// new_cd is where we will cd to once we start running.
char *new_cd = NULL;

// persist_dir is where we will store overlayfs data.
// Specifying this will allow subsequent invocations to persist temporary state.
char * persist_dir = NULL;

enum {
  MOUNT_TYPE_READWRITE,
  MOUNT_TYPE_READONLY,
  MOUNT_TYPE_OVERLAYED,
  MOUNT_TYPE_OVERLAYED_READONLY,
};

// Linked list of volume mappings
struct mount_list {
    char *mount_point;
    char *outside_path;
    int type;
    struct mount_list *prev;
};
struct mount_list *mounts;

// This keeps track of our execution mode
enum {
  UNPRIVILEGED_CONTAINER_MODE,
  PRIVILEGED_CONTAINER_MODE,
};
static int execution_mode;

// Whether we should mount our overlay with the `userxattr` option
static int userxattr = 0;


/*
 * We use this method to get /dev in shape.  If we're running as init, we need to
 * mount full-blown devtmpfs at /dev.  If we're just a sandbox, we only bindmount
 * /dev/{tty,null,urandom,pts,ptmx} into our root_dir.  /dev/shm is not the host's:
 * `mount_private()` mounts a fresh one from within the sandbox's IPC namespace.
 */
static void mount_dev(const char * root_dir) {
  char path[PATH_MAX];

  // These are all things that should exist in the host environment, but may not
  // We use `bind_host_node()` to bindmount them into our sandbox if they exist.
  bind_host_node(root_dir, "/dev/null", FALSE);
  bind_host_node(root_dir, "/dev/tty", FALSE);
  bind_host_node(root_dir, "/dev/zero", FALSE);
  bind_host_node(root_dir, "/dev/random", FALSE);
  bind_host_node(root_dir, "/dev/urandom", FALSE);

  // Create the mount point for `mount_private()`, which runs in the cloned child.
  snprintf(path, sizeof(path), "%s/dev/shm", root_dir);
  mkpath(path);

  // Bindmount the sysfs, but make it read-only
  bind_host_node(root_dir, "/sys", TRUE);

  // /dev/pts and /dev/ptmx are more special; we actually mount a new filesystem
  // on /dev/pts, and then bind-mount /dev/pts/ptmx to /dev/ptmx within the
  // sandbox itself.
  snprintf(path, sizeof(path), "%s/dev/pts", root_dir);
  mkpath(path);
  check(0 == mount("devpts", path, "devpts", 0, "ptmxmode=0666"));

  snprintf(path, sizeof(path), "%s/dev/pts/ptmx", root_dir);
  char ptmx_dst[PATH_MAX];
  snprintf(ptmx_dst, sizeof(ptmx_dst), "%s/dev/ptmx", root_dir);
  bind_mount(path, ptmx_dst, FALSE);
}

/*
 * Helper function that mounts pretty much everything:
 *   - procfs/devtmpfs/etc...
 *   - the rootfs
 *   - any other mounts, read-write, read-only, overlayed, etc...
 */
static void mount_the_world(const char * root_dir,
                            struct mount_list * maps,
                            uid_t uid, gid_t gid,
                            const char * persist_dir,
                            const char * tmpfs_size) {
  // If `persist_dir` is specified, it represents a host directory that should
  // be used to store our overlayfs work data.  This is where modifications to
  // the rootfs and such will go.  Typically, these should be ephemeral (and if
  // `persist_dir` is `NULL`, it will be mounted in a `tmpfs` so that the
  // modifcations are lost immediately) but if `persist_dir` is given, the
  // mounting will be done with modifications stored in that directory.
  // The caller will be responsible for cleaning up the `work` and `upper`
  // directories wtihin `persist_dir`, but subsequent invocations of `sandbox`
  // with the same `--persist` argument will allow resuming execution inside of
  // a rootfs with the previous modifications intact.
  if (persist_dir == NULL) {
    // We know that `/bin` will always be available on basically any Linux
    // system, so we mount our tmpfs here.
    persist_dir = "/bin";
    userxattr = 0;

    // Create tmpfs to store ephemeral changes.  These changes are lost once
    // the `tmpfs` is unmounted, which occurs when all processes within the
    // namespace exit and the mount namespace is destroyed.
    char options[32];
    int n = snprintf(options, 32, "size=%s", tmpfs_size);
    check(0 < n);
    check(n < 31);
    check(0 == mount("tmpfs", "/bin", "tmpfs", 0, options));
  }

  if (verbose) {
    fprintf(stderr, "--> Creating overlay workdir at %s\n", persist_dir);
  }

  // The first thing we do is create an overlay mounting `root_dir` over itself.
  // We need to do this immediately as we may need to create mountpoints for
  // the rest of our mounts within the rootfs, without modifying it.
  // `root_dir` is the path to the already-mounted rootfs image, and we are
  // mounting it as an overlay over itself, so that we can make modifications
  // without altering the actual rootfs image.  When running in privileged mode,
  // we're mounting before cloning, in unprivileged mode, we clone before calling
  // this mehod at all.
  check(TRUE == mount_overlay(root_dir, root_dir, "rootfs", persist_dir, userxattr));

  // Chown this directory to the desired UID/GID, so that it doesn't look like it's
  // owned by "nobody" when we're inside the sandbox.
  check(0 == chown(root_dir, uid, gid));

  // Mount all of our mounts
  struct mount_list *entry = maps;
  while (entry != NULL) {
    char path[PATH_MAX];
    char *inside = entry->mount_point;

    // Construct `${root_dir}/${mount_point}`:
    while (inside[0] == '/') {
      inside = inside + 1;
    }
    snprintf(path, sizeof(path), "%s/%s", root_dir, inside);

    // bind-mount the outside path to the computed inside path,
    // setting the bind-mount to be read-only if requested.
    bind_mount(entry->outside_path,
               path,
               entry->type == MOUNT_TYPE_READONLY || entry->type == MOUNT_TYPE_OVERLAYED || entry->type == MOUNT_TYPE_OVERLAYED_READONLY);

    // If we're dealing with an overlayed mount, create a unique
    // name to store the state of this mount within our `persist_dir`.
    if (entry->type == MOUNT_TYPE_OVERLAYED || entry->type == MOUNT_TYPE_OVERLAYED_READONLY) {
      char bname[PATH_MAX];
      hashed_basename(&bname[0], entry->mount_point);
      check(TRUE == mount_overlay(path, path, bname, persist_dir, userxattr));
      check(0 == chown(path, uid, gid));

      // If this is a "read-only" overlay mount, remount as read-only here.
      if (entry->type == MOUNT_TYPE_OVERLAYED_READONLY) {
        check(0 == mount("overlay", path, "overlay", MS_REMOUNT|MS_RDONLY, ""));
      }
    }
    entry = entry->prev;
  }

  // Mount /proc within the sandbox.
  mount_procfs(root_dir, uid, gid);

  // Mount /dev stuff
  mount_dev(root_dir);
}

/*
 * Mounts that belong to the namespaces of the cloned child rather than to the host,
 * so they are made after `clone()` in both execution modes:
 *   - a fresh tmpfs on /dev/shm, private to the sandbox like its IPC namespace;
 *     its pages are charged to the memory cgroup of the processes that use them.
 *   - a read-only cgroup2 mount on /sys/fs/cgroup, rooted at the cgroup the sandbox
 *     was started in (the root of its cgroup namespace).  It covers the host's
 *     writable hierarchy that came in with /sys, so the sandbox can read its own
 *     limits (as /proc/self/cgroup says `0::/`) but cannot reach any other cgroup.
 *     On hosts without a cgroup2 hierarchy at /sys/fs/cgroup there is no such view
 *     to give, so the host's hierarchies are hidden behind an empty tmpfs instead.
 */
static void mount_private(const char * root_dir, const char * shm_size) {
  char path[PATH_MAX];
  char options[64];
  int n;

  snprintf(path, sizeof(path), "%s/dev/shm", root_dir);
  if (shm_size != NULL) {
    n = snprintf(options, sizeof(options), "mode=1777,size=%s", shm_size);
  } else {
    n = snprintf(options, sizeof(options), "mode=1777");
  }
  check(0 < n && n < sizeof(options));
  if (verbose) {
    fprintf(stderr, "--> Mounting tmpfs at %s (%s)\n", path, options);
  }
  check(0 == mount("tmpfs", path, "tmpfs", MS_NOSUID|MS_NODEV, options));

  struct statfs cgroup_fs;
  snprintf(path, sizeof(path), "%s/sys/fs/cgroup", root_dir);
  if (statfs(path, &cgroup_fs) != 0) {
    // No /sys/fs/cgroup on the host, so nothing to cover.
    return;
  }
  unsigned long cgroup_flags = MS_NOSUID|MS_NODEV|MS_NOEXEC;
  if (cgroup_fs.f_type == CGROUP2_SUPER_MAGIC) {
    if (verbose) {
      fprintf(stderr, "--> Mounting cgroup2 at %s (read-only)\n", path);
    }
    // The new mount shares its superblock with the host's mount it covers, which
    // mount(2) refuses to stack directly (EBUSY), and the superblock is writable, so
    // it cannot be asked for read-only either.  Mount it in the scratch space of the
    // fresh /dev/shm, make that mount read-only, then move it into place.
    char staging[PATH_MAX];
    snprintf(staging, sizeof(staging), "%s/dev/shm/.cgroup", root_dir);
    check(0 == mkdir(staging, 0700));
    if (0 != mount("cgroup2", staging, "cgroup2", cgroup_flags, NULL)) {
      fprintf(stderr, "ERROR: Failed to mount cgroup2: %s (errno %d)\n",
              strerror(errno), errno);
      _exit(EXIT_SANDBOX_FAILED);
    }
    check(0 == mount(NULL, staging, NULL, MS_REMOUNT|MS_BIND|MS_RDONLY|cgroup_flags, NULL));
    check(0 == mount(staging, path, NULL, MS_MOVE, NULL));
    check(0 == rmdir(staging));
  } else {
    if (verbose) {
      fprintf(stderr, "--> No cgroup2 hierarchy at %s, hiding it behind an empty tmpfs\n", path);
    }
    check(0 == mount("tmpfs", path, "tmpfs", MS_RDONLY|cgroup_flags, "size=4k,mode=0755"));
  }
}

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
  configure_user_namespace(getpid(), uid, gid, uid, gid);

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
 * Sets up the chroot jail, then executes the target executable.
 */
static int sandbox_main(const char * root_dir, const char * new_cd, int sandbox_argc, char **sandbox_argv, int *parent_pipe) {
  int status;

  // One of the few places where we need to not use `""`, but instead expand it to `"/"`
  if (root_dir[0] == '\0') {
    root_dir = "/";
  }

  // Use `pivot_root()` to avoid bad interaction between `chroot()` and `clone()`,
  // where we get an EPERM on nested sandboxing.
  if (verbose) {
    fprintf(stderr, "Entering rootfs at %s\n", root_dir);
  }
  check(0 == chdir(root_dir));
  if (syscall(SYS_pivot_root, ".", ".") == 0) {
    // Unmount `.`, which will unmount the old root, since that's the first mountpoint in this directory
    check(0 == umount2(".", MNT_DETACH));
    check(0 == chdir("/"));

    if (verbose) {
      fprintf(stderr, "--> pivot_root() succeeded and unmounted old root\n");
    }
  } else {
    check(0 == chroot(root_dir));
    if (verbose) {
      fprintf(stderr, "--> chroot() used since pivot_root() errored with: [%d] %s; locking the sandbox will fail\n", errno, strerror(errno));
    }
  }

  // All mounts are in place, so lock them before running anything.
  lock_sandbox();

  // Our next child is the init of the sandboxed processes' PID namespace; it reports
  // their exit status to the parent itself.  We only pass signals on to it.
  pid_t init_pid = fork();
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
  mount_procfs("", geteuid(), getegid());

  // If we've got a directory to change to, do so, creating it if we need to
  if (new_cd) {
    mkpath(new_cd);
    check(0 == chdir(new_cd));
  }

  // When the main pid dies, we exit.
  if ((child_pid = fork()) == 0) {
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

static void print_help() {
  fputs("Usage: sandbox --rootfs <dir> [--cd <dir>] ", stderr);
  fputs("[--map <from>:<to>, --map <from>:<to>, ...] ", stderr);
  fputs("[--workspace <from>:<to>, --workspace <from>:<to>, ...] ", stderr);
  fputs("[--persist <work_dir>] ", stderr);
  fputs("[--entrypoint <exe_path>] ", stderr);
  fputs("[--userxattr] ", stderr);
  fputs("[--shm-size <size>] ", stderr);
  fputs("[--verbose] [--help] <cmd>\n", stderr);
  fputs("\nExample:\n", stderr);
  fputs("  mkdir -p /tmp/workspace\n", stderr);
  fputs("  /tmp/sandbox --verbose --rootfs $rootfs_path --workspace /tmp/workspace:/workspace --cd /workspace /bin/bash\n", stderr);
}

/*
 * Let's get this party started.
 */
int main(int sandbox_argc, char **sandbox_argv) {
  int status = 0;
  pid_t pgrp = getpgid(0);
  char * entrypoint = NULL;
  const char * hostname = NULL;

  // First, determine our execution mode based on pid and euid (allowing for override)
  const char * forced_mode = getenv("FORCE_SANDBOX_MODE");
  if (forced_mode != NULL) {
    if (strcmp(forced_mode, "privileged") == 0) {
      execution_mode = PRIVILEGED_CONTAINER_MODE;
    } else if (strcmp(forced_mode, "unprivileged") == 0) {
      execution_mode = UNPRIVILEGED_CONTAINER_MODE;
    } else {
      fprintf(stderr, "ERROR: Unknown FORCE_SANDBOX_MODE argument \"%s\"\n", forced_mode);
      _exit(EXIT_SANDBOX_FAILED);
    }
  } else {
    if(geteuid() == 0) {
      execution_mode = PRIVILEGED_CONTAINER_MODE;
    } else {
      execution_mode = UNPRIVILEGED_CONTAINER_MODE;
    }

    // Once we're inside the sandbox, we can always use "unprivileged" mode
    // since we've got mad permissions inside; so just always do that.
    setenv("FORCE_SANDBOX_MODE", "unprivileged", 0);
  }

  uid_t uid = getuid();
  gid_t gid = getgid();

  // If we're running inside of `sudo`, we need to grab the UID/GID of the calling user through
  // environment variables, not using `getuid()` or `getgid()`.  :(
  const char * SUDO_UID = getenv("SUDO_UID");
  if (SUDO_UID != NULL && SUDO_UID[0] != '\0') {
    uid = strtol(SUDO_UID, NULL, 10);
  }
  const char * SUDO_GID = getenv("SUDO_GID");
  if (SUDO_GID != NULL && SUDO_GID[0] != '\0') {
    gid = strtol(SUDO_GID, NULL, 10);
  }

  // Hide these from children so that we don't carry the outside UID numbers into
  // nested sandboxen; that would cause problems when we refer to UIDs that don't exist.
  unsetenv("SUDO_UID");
  unsetenv("SUDO_GID");

  uid_t dst_uid = 0;
  gid_t dst_gid = 0;

  char * tmpfs_size = "1G"; // default value if the `--tmpfs-size` option is not provided
  char * shm_size = NULL;   // size of /dev/shm; the tmpfs default (half of RAM) if not given

  // Parse out options
  while(1) {
    static struct option long_options[] = {
      {"help",       no_argument,       NULL, 'h'},
      {"verbose",    no_argument,       NULL, 'v'},
      {"rootfs",     required_argument, NULL, 'r'},
      {"entrypoint", required_argument, NULL, 'e'},
      {"persist",    required_argument, NULL, 'p'},
      {"cd",         required_argument, NULL, 'c'},
      {"mount",      required_argument, NULL, 'm'},
      {"uid",        required_argument, NULL, 'u'},
      {"gid",        required_argument, NULL, 'g'},
      {"tmpfs-size", required_argument, NULL, 't'},
      {"shm-size",   required_argument, NULL, 's'},
      {"userxattr",  no_argument,       NULL, 'x'},
      {"hostname",   required_argument, NULL, 'H'},
      {0, 0, 0, 0}
    };

    int opt_idx;
    int c = getopt_long(sandbox_argc, sandbox_argv, "", long_options, &opt_idx);

    // End of options
    if( c == -1 )
      break;

    switch( c ) {
      case 'h':
        print_help();
        return 0;
      case '?':
        // getopt already printed what was wrong; an option we don't know must not
        // look like a successful run to a caller that expected it to take effect.
        print_help();
        return EXIT_SANDBOX_FAILED;
      case 'v':
        verbose = 1;
        fprintf(stderr, "verbose sandbox enabled (running in ");
        switch (execution_mode) {
          case UNPRIVILEGED_CONTAINER_MODE:
            fprintf(stderr, "un");
          case PRIVILEGED_CONTAINER_MODE:
            fprintf(stderr, "privileged container");
            break;
        }
        fprintf(stderr, " mode)\n");
        break;
      case 'r': {
        sandbox_root = strdup(optarg);
        size_t sandbox_root_len = strlen(sandbox_root);
        if (sandbox_root[sandbox_root_len-1] == '/' ) {
            sandbox_root[sandbox_root_len-1] = '\0';
        }
        if (verbose) {
          fprintf(stderr, "Parsed --rootfs as \"%s\"\n", sandbox_root);
        }
      } break;
      case 'c':
        new_cd = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --cd as \"%s\"\n", new_cd);
        }
        break;
      case 'm': {
        // Find the colon in "from:to"
        char *colon = strchr(optarg, ':');
        if (colon == NULL) {
          fprintf(stderr, "ERROR: --mount \"%s\" is not of the form <from>:<to>[:<type>]!\n", optarg);
          return EXIT_SANDBOX_FAILED;
        }

        // Extract "from" and "to"
        char *from = strndup(optarg, (colon - optarg));
        char *to = strdup(colon + 1);
        if (from[0] != '/') {
          fprintf(stderr, "ERROR: Outside path \"%s\" must be absolute!\n", from);
          return EXIT_SANDBOX_FAILED;
        }

        // Look for mount options
        int mount_type = MOUNT_TYPE_READWRITE;
        char *mount_str = strchr(to, ':');
        if (mount_str != NULL) {
          // Chop off the colon so `to` is NULL-terminated.
          *mount_str = '\0';
          mount_str++;
          if (strcmp(mount_str, "ro") == 0) {
            mount_type = MOUNT_TYPE_READONLY;
          } else if (strcmp(mount_str, "ov") == 0) {
            mount_type = MOUNT_TYPE_OVERLAYED;
          } else if (strcmp(mount_str, "rov") == 0) {
            mount_type = MOUNT_TYPE_OVERLAYED_READONLY;
          } else if (strcmp(mount_str, "rw") == 0) {
            mount_type = MOUNT_TYPE_READWRITE;
          } else {
            fprintf(stderr, "ERROR: Unknown mount type in \"%s\" -> \"%s\" with type \"%s\"!\n", from, to, mount_str);
            return EXIT_SANDBOX_FAILED;
          }
        }

        // Construct `mount_list` object for this `from:to:type` pair
        struct mount_list *entry = (struct mount_list *) malloc(sizeof(struct mount_list));
        entry->mount_point = to;
        entry->outside_path = from;
        entry->type = mount_type;
        entry->prev = mounts;
        mounts = entry;

        if (verbose) {
          fprintf(stderr, "Parsed --mount as \"%s\" -> \"%s\" (\"%s\")\n",
                  entry->outside_path, entry->mount_point, mount_str);
        }
      } break;
      case 'p':
        persist_dir = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --persist as \"%s\"\n", persist_dir);
        }
        break;
      case 'u':
        dst_uid = atoi(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --uid as \"%d\"\n", dst_uid);
        }
        break;
      case 'g':
        dst_gid = atoi(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --gid as \"%d\"\n", dst_gid);
        }
        break;
      case 'e':
        entrypoint = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --entrypoint as \"%s\"\n", entrypoint);
        }
        break;
      case 't':
        tmpfs_size = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --tmpfs-size as \"%s\"\n", tmpfs_size);
        }
        break;
      case 's':
        shm_size = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --shm-size as \"%s\"\n", shm_size);
        }
        break;
      case 'H':
        hostname = strdup(optarg);
        if (verbose) {
          fprintf(stderr, "Parsed --hostname as \"%s\"\n", hostname);
        }
        break;
      case 'x':
        userxattr = 1;
        break;
      default:
        fputs("getoptlong defaulted?!\n", stderr);
        return EXIT_SANDBOX_FAILED;
    }
  }

  // Skip past those arguments
  sandbox_argv += optind;
  sandbox_argc -= optind;

  // If we were given an entrypoint, push that onto the front of `sandbox_argv`
  if (entrypoint != NULL) {
    // Yes, we clobber sandbox_argv[-1] here; but we already know that `optind` >= 2
    // since `entrypoint != NULL`, so this is acceptable.
    sandbox_argv -= 1;
    sandbox_argc += 1;
    sandbox_argv[0] = entrypoint;
  }

  // If we don't have a command, die
  if (sandbox_argc == 0) {
    fputs("No <cmd> given!\n", stderr);
    print_help();
    return EXIT_SANDBOX_FAILED;
  }

  // If we haven't been given a sandbox root, die
  if (!sandbox_root) {
    fputs("--rootfs is required!\n", stderr);
    print_help();
    return EXIT_SANDBOX_FAILED;
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
    // We dissociate ourselves from the typical mount namespace.  This gives us the freedom
    // to start mounting things willy-nilly without mucking up the user's computer.
    check(0 == unshare(CLONE_NEWNS));

    // Even if we unshare, we might need to mark `/` as private, as systemd often subverts
    // the kernel's default value of `MS_PRIVATE` on the root mount.  This doesn't effect
    // the main root mount, because we have unshared, but this prevents our changes to
    // any subtrees of `/` (e.g. everything) from propagating back to the outside `/`.
    check(0 == mount(NULL, "/", NULL, MS_PRIVATE|MS_REC, NULL));

    // Mount the rootfs, shards, and workspace.  We do this here because, on this machine,
    // we may not have permissions to mount overlayfs within user namespaces.
    mount_the_world(sandbox_root, mounts, uid, gid, persist_dir, tmpfs_size);
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

      // The /proc mountpoint previously mounted is in the wrong PID namespace;
      // mount a new procfs over it to to get better values:
      mount_procfs(sandbox_root, dst_uid, dst_gid);
    } else if (execution_mode == UNPRIVILEGED_CONTAINER_MODE) {
      // If we're in unprivileged container mode, mount the world now that we
      // have supreme cosmic power.
      mount_the_world(sandbox_root, mounts, dst_uid, dst_gid, persist_dir, tmpfs_size);
    }
    mount_private(sandbox_root, shm_size);

    if (execution_mode == PRIVILEGED_CONTAINER_MODE) {
      // The rootfs was mounted before we entered this user namespace, so the kernel
      // locked it to its parent, and `pivot_root()` refuses a locked mount.  A
      // recursive bind of it made from in here is not locked itself.
      check(0 == mount(sandbox_root, sandbox_root, NULL, MS_BIND|MS_REC, NULL));
    }

    // Set the hostname, if that's been requested
    if (hostname != NULL) {
        check(sethostname(hostname, strlen(hostname)) == 0);
    }

    // Finally, we begin invocation of the target program.
    return sandbox_main(sandbox_root, new_cd, sandbox_argc, sandbox_argv, parent_pipe);
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

    // Kill ourselves with the same signal
    signal(child_signal, SIG_DFL);
    check(raise(child_signal));
  } else {
    if (verbose) {
      fprintf(stderr, "Child Process %d exited with code %d\n", child_pid, child_exit_code);
    }
    return child_exit_code;
  }
}

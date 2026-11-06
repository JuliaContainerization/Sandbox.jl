/* Copyright (c) 2023 JuliaHub Inc and contributors */
#define _GNU_SOURCE

#include "userns_common.h"

static void print_help() {
  fputs("Usage: userns_overlay_probe ", stderr);
  fputs("[--userxattr] ", stderr);
  fputs("[--tmpfs] ", stderr);
  fputs("[--verbose] [--help] <rootfs_dir> <upper_dir>\n", stderr);
  fputs("\nExample:\n", stderr);
  fputs("  userns_overlay_probe --verbose --userxattr --tmpfs ${HOME}/rootfs /tmp\n", stderr);
}

/*
 * Let's get this party started.
 */
int main(int sandbox_argc, char **sandbox_argv) {
  int status = 0;
  pid_t pgrp = getpgid(0);

  uid_t uid = getuid();
  gid_t gid = getgid();
  uid_t dst_uid = 0;
  gid_t dst_gid = 0;

  uint8_t mount_tmpfs = 0;
  uint8_t userxattr = 0;

  // Parse out options
  while(1) {
    static struct option long_options[] = {
      {"help",       no_argument,       NULL, 'h'},
      {"verbose",    no_argument,       NULL, 'v'},
      {"uid",        required_argument, NULL, 'u'},
      {"gid",        required_argument, NULL, 'g'},
      {"tmpfs",      no_argument,       NULL, 't'},
      {"userxattr",  no_argument,       NULL, 'x'},
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
        return 1;
      case 'v':
        verbose = 1;
        fprintf(stderr, "verbose overlay_probe enabled\n");
        break;
      case 't':
        mount_tmpfs = 1;
        break;
      case 'x':
        userxattr = 1;
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
      default:
        fputs("getoptlong defaulted?!\n", stderr);
        return 1;
    }
  }

  // Skip past those arguments
  sandbox_argv += optind;
  sandbox_argc -= optind;

  // If we don't have a directory to test, die
  if (sandbox_argc < 1) {
    fputs("No <rootfs_dir> given!\n", stderr);
    print_help();
    return 1;
  }
  // If we don't have a directory to test, die
  if (sandbox_argc < 2) {
    fputs("No <work_dir> given!\n", stderr);
    print_help();
    return 1;
  }

  // If we're running in one of the container modes, we're going to syscall() ourselves a
  // new, cloned process that is in a container process. We will use a pipe for synchronization.
  // The regular SIGSTOP method does not work because container-inits don't receive STOP or KILL
  // signals from within their own pid namespace.
  int child_pipe[2], parent_pipe[2];
  check(0 == pipe(child_pipe));
  check(0 == pipe(parent_pipe));

  // We want to request a new PID space, a new mount space, and a new user space
  int clone_flags = CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWUSER | CLONE_NEWUTS | SIGCHLD;
  if ((child_pid = syscall(SYS_clone, clone_flags, 0, 0, 0, 0)) == 0) {
    // If we're in here, we have become the "child" process, within the container.

    // Get rid of the ends of the synchronization pipe that I'm not going to use
    close(child_pipe[1]);
    close(parent_pipe[0]);

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

    // Create a file in the specified directory
    char * rootfs_dir = sandbox_argv[0];
    char * probe_parent_dir = sandbox_argv[1];
    if (!isdir(probe_parent_dir)) {
      fprintf(stderr, "---> parent directory does not exist (%s)\n", probe_parent_dir);
      return 1;
    }

    char probe_dir[PATH_MAX];
    snprintf(probe_dir, sizeof(probe_dir), "%s/.probe", probe_parent_dir);

    // If `mount_tmpfs` is set, then mount a `tmpfs` over `probe_dir`
    if (mount_tmpfs) {
      if (verbose) {
        fprintf(stderr, "--> Mounting tmpfs on %s\n", probe_dir);
      }
      mkpath(probe_dir);
      check(0 == mount("tmpfs", probe_dir, "tmpfs", 0, "size=1M"));
    }

    // Mount an overlay filesystem with the probe directory as the "work" directory.
    uint8_t ret = mount_overlay(rootfs_dir, rootfs_dir, "probe", probe_dir, userxattr);

    if (ret == TRUE) {
      // Test directory renaming (this ensures that our kernel can handle this combination
      // of `userxattr`, `redirect_dir`, etc...).  This is basically the test that ensures
      // `apt` can install stuff without hitting `EXDEV` errors.
      char move_dir_src[PATH_MAX+5], move_dir_dst[PATH_MAX+5];
      snprintf(move_dir_src, sizeof(move_dir_src), "%s/src", rootfs_dir);
      snprintf(move_dir_dst, sizeof(move_dir_dst), "%s/dst", rootfs_dir);
      mkpath(move_dir_src);
      if (0 != rename(move_dir_src, move_dir_dst)) {
        if (verbose) {
          fprintf(stderr, "----> rename(\"%s\", \"%s\") failed: %d (%s)\n", move_dir_src, move_dir_dst, errno, strerror(errno));
        }
        ret = FALSE;
      }
      if (verbose) {
        fprintf(stderr, "----> rename(\"%s\", \"%s\") passed: %d (%s)\n", move_dir_src, move_dir_dst, errno, strerror(errno));
      }
    }

    check(0 == umount(rootfs_dir));
    if (mount_tmpfs) {
      check(0 == umount(probe_dir));
    }

    rmrf(probe_dir);

    if (ret == TRUE && verbose) {
      printf("---> probe of %s successful!\n", probe_parent_dir);
    }
    return TRUEFALSE_EXITCODE(ret);
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

  // The child sandbox should alway exit cleanly, with a zero or one exit status.
  check(WIFEXITED(status));
  return WEXITSTATUS(status);
}

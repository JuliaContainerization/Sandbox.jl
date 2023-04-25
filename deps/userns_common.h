/* Copyright (c) 2023 JuliaHub Inc and contributors */
#define _GNU_SOURCE

/* Seperate because the headers below don't have all dependencies properly
   declared */
#include <sys/socket.h>

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/socket.h>
#include <linux/if.h>
#include <linux/in.h>
#include <linux/netlink.h>
#include <linux/route.h>
#include <linux/rtnetlink.h>
#include <linux/sockios.h>
#include <linux/veth.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <signal.h>
#include <sys/xattr.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dirent.h>
#include <libgen.h>
#include <sys/reboot.h>
#include <linux/reboot.h>
#include <linux/limits.h>
#include <getopt.h>
#include <byteswap.h>
#include <mntent.h>
#include <ftw.h>

/**** Global Variables ***/
#define TRUE 1
#define FALSE 0
#define TRUEFALSE_EXITCODE(x) ((x) == TRUE ? 0 : 1)
extern unsigned char verbose;
extern pid_t child_pid;


/* General utilities */
void _check(int ok, const char * file, int line);
#define check(ok) _check(ok, __FILE__, __LINE__)
int open_proc_file(pid_t pid, const char *file, int mode);
void touch(const char * path);
void mkpath(const char * dir);
int isdir(const char * path);
int islink(const char * path);
void rmrf(const char * path);
void hashed_basename(char *output, const char *path);
void signal_passthrough(int sig);
void setup_signal_forwarding();

/* User namespaces */
void configure_user_namespace(pid_t pid, uid_t src_uid, gid_t src_gid, uid_t dst_uid, gid_t dst_gid);
uint8_t mount_overlay(const char * src, const char * dest, const char * bname, const char * work_dir, uint8_t userxattr);
void mount_procfs(const char * root_dir, uid_t uid, gid_t gid);
void bind_mount(const char *src, const char *dest, char read_only);
void bind_host_node(const char *root_dir, const char *name, char read_only);

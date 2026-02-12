/*
 * lazy_handler.c — Custom lazy-pages daemon for CRIU restore
 *
 * Drop-in replacement for "criu lazy-pages". Listens on a Unix socket
 * for CRIU restore to send PID + userfaultfd via SCM_RIGHTS, then
 * monitors the uffd for page faults and fetches pages from our TCP
 * page server (criu_page_server.py).
 *
 * CRIU lazy-pages Unix socket protocol:
 *   1. Restore sends PID (4 bytes, int32)
 *   2. Restore sends uffd fd via sendmsg SCM_RIGHTS
 *   3. Restore sends magic 0x52535446 ("RSTF") when restore is finished
 *
 * Usage:
 *   lazy_handler --images-dir DIR --address ADDR --port PORT
 */

#define _GNU_SOURCE
#include <linux/userfaultfd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <limits.h>

#define PAGE_SIZE 4096
#define CRIU_LAZY_PAGES_SOCKET "lazy-pages.socket"
#define RESTORE_FINISH_MAGIC 0x52535446  /* "RSTF" */

static volatile int got_signal = 0;

static void signal_handler(int sig)
{
	(void)sig;
	got_signal = 1;
}

/*
 * Create and bind the Unix socket that CRIU restore connects to.
 */
static int setup_unix_socket(const char *images_dir)
{
	int fd;
	struct sockaddr_un addr;
	char path[PATH_MAX];

	snprintf(path, sizeof(path), "%s/%s", images_dir, CRIU_LAZY_PAGES_SOCKET);

	/* Remove stale socket */
	unlink(path);

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		perror("socket(AF_UNIX)");
		return -1;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("bind");
		close(fd);
		return -1;
	}

	if (listen(fd, 1) < 0) {
		perror("listen");
		close(fd);
		return -1;
	}

	printf("Listening on %s\n", path);
	return fd;
}

/*
 * Receive PID from CRIU restore (4 bytes).
 */
static int recv_pid(int conn_fd, int *pid_out)
{
	int32_t pid;
	ssize_t n = recv(conn_fd, &pid, sizeof(pid), MSG_WAITALL);
	if (n != sizeof(pid)) {
		perror("recv pid");
		return -1;
	}
	*pid_out = pid;
	return 0;
}

/*
 * Receive userfaultfd via SCM_RIGHTS from CRIU restore.
 */
static int recv_uffd(int conn_fd)
{
	struct msghdr msg = {0};
	struct iovec iov;
	char buf[1];
	char cmsgbuf[CMSG_SPACE(sizeof(int))];
	struct cmsghdr *cmsg;
	int uffd = -1;

	iov.iov_base = buf;
	iov.iov_len = sizeof(buf);

	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cmsgbuf;
	msg.msg_controllen = sizeof(cmsgbuf);

	ssize_t n = recvmsg(conn_fd, &msg, 0);
	if (n < 0) {
		perror("recvmsg");
		return -1;
	}

	cmsg = CMSG_FIRSTHDR(&msg);
	if (cmsg && cmsg->cmsg_level == SOL_SOCKET &&
	    cmsg->cmsg_type == SCM_RIGHTS) {
		memcpy(&uffd, CMSG_DATA(cmsg), sizeof(int));
	}

	if (uffd < 0) {
		fprintf(stderr, "Failed to receive uffd via SCM_RIGHTS\n");
		return -1;
	}

	return uffd;
}

/*
 * Connect to our TCP page server.
 */
static int connect_page_server(const char *address, int port)
{
	int fd;
	struct sockaddr_in serv_addr;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		perror("socket(TCP)");
		return -1;
	}

	memset(&serv_addr, 0, sizeof(serv_addr));
	serv_addr.sin_family = AF_INET;
	serv_addr.sin_port = htons(port);

	if (inet_pton(AF_INET, address, &serv_addr.sin_addr) <= 0) {
		perror("inet_pton");
		close(fd);
		return -1;
	}

	if (connect(fd, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
		perror("connect to page server");
		close(fd);
		return -1;
	}

	printf("Connected to page server at %s:%d\n", address, port);
	return fd;
}

/*
 * Fetch a page from the TCP page server.
 * Sends 8-byte address, receives PAGE_SIZE bytes.
 */
static int fetch_page(int tcp_fd, uint64_t addr, void *buf)
{
	if (send(tcp_fd, &addr, sizeof(addr), 0) != sizeof(addr)) {
		perror("send page request");
		return -1;
	}

	int total = 0;
	while (total < PAGE_SIZE) {
		int r = recv(tcp_fd, (char *)buf + total, PAGE_SIZE - total, 0);
		if (r <= 0) {
			perror("recv page data");
			return -1;
		}
		total += r;
	}

	return 0;
}

/*
 * Main page-fault handling loop.
 *
 * Uses poll() to monitor:
 *   - uffd for page fault events
 *   - Unix socket connection for restore-finish magic
 */
static int handle_faults(int uffd, int conn_fd, int tcp_fd)
{
	struct pollfd fds[2];
	struct uffd_msg msg;
	struct uffdio_copy uffdio_copy;
	char *page;
	int restore_finished = 0;
	int pages_served = 0;

	if (posix_memalign((void **)&page, PAGE_SIZE, PAGE_SIZE) != 0) {
		perror("posix_memalign");
		return -1;
	}

	setbuf(stdout, NULL);  /* Unbuffered for log visibility */
	printf("Handling page faults...\n");

	for (;;) {
		int nfds = 0;

		fds[0].fd = uffd;
		fds[0].events = POLLIN;
		fds[0].revents = 0;
		nfds = 1;

		if (!restore_finished && conn_fd >= 0) {
			fds[1].fd = conn_fd;
			fds[1].events = POLLIN;
			fds[1].revents = 0;
			nfds = 2;
		}

		int ret = poll(fds, nfds, 1000);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			break;
		}

		if (ret == 0) {
			/* Timeout — check if we should exit */
			if (got_signal)
				break;
			if (restore_finished) {
				/* After restore finished, if uffd has no more events, we're done */
			}
			continue;
		}

		/* Check Unix socket for restore-finish magic */
		if (nfds > 1 && (fds[1].revents & POLLIN)) {
			uint32_t magic;
			ssize_t n = recv(conn_fd, &magic, sizeof(magic), MSG_WAITALL);
			if (n == sizeof(magic) && magic == RESTORE_FINISH_MAGIC) {
				printf("Restore finished (magic received)\n");
				restore_finished = 1;
			} else if (n <= 0) {
				/* Connection closed */
				restore_finished = 1;
			}
		}

		/* Check uffd for page faults */
		if (fds[0].revents & POLLIN) {
			ssize_t nread = read(uffd, &msg, sizeof(msg));
			if (nread == 0) {
				printf("EOF on userfaultfd\n");
				break;
			}
			if (nread < 0) {
				if (errno == EAGAIN)
					continue;
				perror("read uffd");
				break;
			}

			if (msg.event != UFFD_EVENT_PAGEFAULT) {
				fprintf(stderr, "Unexpected uffd event: %d\n", msg.event);
				continue;
			}

			uint64_t fault_addr = msg.arg.pagefault.address;
			uint64_t page_addr = fault_addr & ~(PAGE_SIZE - 1UL);

			/* Fetch from TCP page server */
			if (fetch_page(tcp_fd, page_addr, page) < 0) {
				fprintf(stderr, "Failed to fetch page %#lx\n",
					(unsigned long)page_addr);
				/* Serve a zero page as fallback */
				memset(page, 0, PAGE_SIZE);
			}

			uffdio_copy.src = (unsigned long)page;
			uffdio_copy.dst = (unsigned long)page_addr;
			uffdio_copy.len = PAGE_SIZE;
			uffdio_copy.mode = 0;
			uffdio_copy.copy = 0;

			if (ioctl(uffd, UFFDIO_COPY, &uffdio_copy) < 0) {
				if (errno == EEXIST) {
					/* Page already mapped (race), not an error */
					continue;
				}
				perror("ioctl UFFDIO_COPY");
				break;
			}

			pages_served++;
			if (pages_served % 100 == 0 || pages_served <= 10) {
				printf("Served page %d: %#lx\n",
				       pages_served, (unsigned long)page_addr);
			}
		}

		/* uffd hung up — all VMAs unregistered, process exited or no more lazy pages */
		if (fds[0].revents & POLLHUP) {
			printf("POLLHUP on userfaultfd — done\n");
			break;
		}
	}

	printf("Total pages served: %d\n", pages_served);
	free(page);
	return 0;
}

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s --images-dir DIR --address ADDR --port PORT\n"
		"\n"
		"Custom lazy-pages daemon for CRIU restore.\n"
		"  --images-dir DIR   CRIU images directory (for socket path)\n"
		"  --address ADDR     TCP page server address\n"
		"  --port PORT        TCP page server port\n",
		prog);
}

int main(int argc, char *argv[])
{
	const char *images_dir = NULL;
	const char *address = "127.0.0.1";
	int port = 9999;
	int opt;

	static struct option long_opts[] = {
		{"images-dir", required_argument, 0, 'd'},
		{"address",    required_argument, 0, 'a'},
		{"port",       required_argument, 0, 'p'},
		{"help",       no_argument,       0, 'h'},
		{0, 0, 0, 0}
	};

	while ((opt = getopt_long(argc, argv, "d:a:p:h", long_opts, NULL)) != -1) {
		switch (opt) {
		case 'd':
			images_dir = optarg;
			break;
		case 'a':
			address = optarg;
			break;
		case 'p':
			port = atoi(optarg);
			break;
		case 'h':
		default:
			usage(argv[0]);
			return opt == 'h' ? 0 : 1;
		}
	}

	if (!images_dir) {
		fprintf(stderr, "ERROR: --images-dir is required\n");
		usage(argv[0]);
		return 1;
	}

	signal(SIGTERM, signal_handler);
	signal(SIGINT, signal_handler);
	signal(SIGPIPE, SIG_IGN);

	/* Step 1: Set up Unix socket */
	int listen_fd = setup_unix_socket(images_dir);
	if (listen_fd < 0)
		return 1;

	/* Step 2: Connect to TCP page server */
	int tcp_fd = connect_page_server(address, port);
	if (tcp_fd < 0) {
		close(listen_fd);
		return 1;
	}

	/* Step 3: Accept connection from CRIU restore */
	printf("Waiting for CRIU restore to connect...\n");
	int conn_fd = accept(listen_fd, NULL, NULL);
	if (conn_fd < 0) {
		perror("accept");
		close(tcp_fd);
		close(listen_fd);
		return 1;
	}
	printf("CRIU restore connected\n");
	close(listen_fd);  /* Only one connection expected */

	/* Step 4: Receive PID */
	int pid;
	if (recv_pid(conn_fd, &pid) < 0) {
		close(conn_fd);
		close(tcp_fd);
		return 1;
	}
	printf("Received PID: %d\n", pid);

	/* Step 5: Receive uffd via SCM_RIGHTS */
	int uffd = recv_uffd(conn_fd);
	if (uffd < 0) {
		close(conn_fd);
		close(tcp_fd);
		return 1;
	}
	printf("Received userfaultfd: %d\n", uffd);

	/* Make uffd non-blocking for poll-based handling */
	int flags = fcntl(uffd, F_GETFL);
	if (flags >= 0)
		fcntl(uffd, F_SETFL, flags | O_NONBLOCK);

	/* Step 6: Handle page faults */
	int rc = handle_faults(uffd, conn_fd, tcp_fd);

	close(uffd);
	close(conn_fd);
	close(tcp_fd);

	return rc < 0 ? 1 : 0;
}

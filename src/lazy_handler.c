/*
 * lazy_handler.c — Custom lazy-pages daemon for CRIU restore
 *
 * Drop-in replacement for "criu lazy-pages". Listens on a Unix socket
 * for CRIU restore to send PID + userfaultfd via SCM_RIGHTS, then
 * monitors the uffd for page faults and fetches pages from our TCP
 * page server (criu_page_server.py).
 *
 * Phase 4 features:
 *   - Prefetching: on fault, pipeline sequential or stride-predicted pages
 *   - Hot page eager fetch: load profiled hot pages via separate thread
 *
 * CRIU lazy-pages Unix socket protocol:
 *   1. Restore sends PID (4 bytes, int32)
 *   2. Restore sends uffd fd via sendmsg SCM_RIGHTS
 *   3. Restore sends magic 0x52535446 ("RSTF") when restore is finished
 *
 * Usage:
 *   lazy_handler --images-dir DIR --address ADDR --port PORT
 *                [--prefetch-seq N] [--prefetch-stride N] [--no-prefetch]
 *                [--hot-pages FILE]
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
#include <stdint.h>
#include <pthread.h>

#include "hashset.h"

#define PAGE_SIZE 4096
#define CRIU_LAZY_PAGES_SOCKET "lazy-pages.socket"
#define RESTORE_FINISH_MAGIC 0x52535446  /* "RSTF" */

#define HISTORY_SIZE 8
#define MAX_PREFETCH_TARGETS 64
#define EAGER_BATCH_SIZE 32

/* ── Global state ─────────────────────────────────────── */

static volatile int got_signal = 0;

struct prefetch_config {
	int seq_count;       /* sequential pages to prefetch (default 16) */
	int stride_count;    /* stride-predicted pages to prefetch (default 8) */
	int enabled;         /* 0 if --no-prefetch */
};

struct prefetch_stats {
	uint64_t total_faults;
	uint64_t prefetch_hits;
	uint64_t pages_prefetched;
};

struct fault_history {
	uint64_t addrs[HISTORY_SIZE];
	int pos;
	int count;
};

struct eager_ctx {
	int uffd;
	const char *address;
	int port;
	const char *hot_pages_file;
	struct hashset *served;
};

static void signal_handler(int sig)
{
	(void)sig;
	got_signal = 1;
}

/* ── Unix socket setup ────────────────────────────────── */

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

/* ── CRIU protocol helpers ────────────────────────────── */

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

/* ── TCP page server connection ───────────────────────── */

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

	return fd;
}

/* ── recv_exact: guaranteed N-byte TCP read ───────────── */

static int recv_exact(int fd, void *buf, int n)
{
	int total = 0;
	while (total < n) {
		int r = recv(fd, (char *)buf + total, n - total, 0);
		if (r <= 0) {
			perror("recv_exact");
			return -1;
		}
		total += r;
	}
	return 0;
}

/* ── Stride detection ─────────────────────────────────── */

static void history_push(struct fault_history *h, uint64_t addr)
{
	h->addrs[h->pos] = addr;
	h->pos = (h->pos + 1) % HISTORY_SIZE;
	if (h->count < HISTORY_SIZE)
		h->count++;
}

/*
 * Detect stride: if last 3 consecutive diffs are equal, return stride.
 * Returns 0 if no consistent stride found.
 */
static int64_t detect_stride(const struct fault_history *h)
{
	if (h->count < 4)
		return 0;

	/* Get last 4 addresses in order */
	uint64_t a[4];
	for (int i = 0; i < 4; i++) {
		int idx = (h->pos - 4 + i + HISTORY_SIZE) % HISTORY_SIZE;
		a[i] = h->addrs[idx];
	}

	int64_t d1 = (int64_t)(a[1] - a[0]);
	int64_t d2 = (int64_t)(a[2] - a[1]);
	int64_t d3 = (int64_t)(a[3] - a[2]);

	if (d1 == d2 && d2 == d3 && d1 != 0) {
		int64_t abs_stride = d1 < 0 ? -d1 : d1;
		if (abs_stride >= PAGE_SIZE && abs_stride <= 256 * (int64_t)PAGE_SIZE)
			return d1;
	}

	return 0;
}

/* ── install_page: UFFDIO_COPY with EEXIST tolerance ─── */

static int install_page(int uffd, uint64_t addr, void *page_buf)
{
	struct uffdio_copy uc;
	uc.src = (unsigned long)page_buf;
	uc.dst = (unsigned long)addr;
	uc.len = PAGE_SIZE;
	uc.mode = 0;
	uc.copy = 0;

	if (ioctl(uffd, UFFDIO_COPY, &uc) < 0) {
		if (errno == EEXIST)
			return 0;  /* already mapped — not an error */
		return -1;
	}
	return 0;
}

/* ── Pipelined fetch + install ────────────────────────── */

static int pipeline_fetch_install(int tcp_fd, int uffd,
				  uint64_t *targets, int ntargets,
				  struct hashset *served, void *page_buf)
{
	/* Send all requests */
	for (int i = 0; i < ntargets; i++) {
		if (send(tcp_fd, &targets[i], sizeof(uint64_t), 0) != sizeof(uint64_t)) {
			perror("send page request");
			return -1;
		}
	}

	/* Receive all responses and install */
	for (int i = 0; i < ntargets; i++) {
		if (recv_exact(tcp_fd, page_buf, PAGE_SIZE) < 0)
			return -1;
		if (install_page(uffd, targets[i], page_buf) == 0)
			hashset_insert(served, targets[i]);
	}

	return 0;
}

/* ── Eager fetch thread (hot pages) ───────────────────── */

static void *eager_fetch_thread(void *arg)
{
	struct eager_ctx *ctx = (struct eager_ctx *)arg;
	FILE *f;
	uint64_t addr;
	uint64_t batch[EAGER_BATCH_SIZE];
	char page_buf[PAGE_SIZE];
	int batch_idx = 0;
	int total_installed = 0;

	/* Open separate TCP connection */
	int tcp_fd = connect_page_server(ctx->address, ctx->port);
	if (tcp_fd < 0) {
		fprintf(stderr, "Eager fetch: failed to connect to page server\n");
		return NULL;
	}

	printf("Eager fetch: connected to page server\n");

	f = fopen(ctx->hot_pages_file, "rb");
	if (!f) {
		fprintf(stderr, "Eager fetch: cannot open %s\n", ctx->hot_pages_file);
		close(tcp_fd);
		return NULL;
	}

	while (fread(&addr, sizeof(uint64_t), 1, f) == 1) {
		if (hashset_contains(ctx->served, addr))
			continue;
		batch[batch_idx++] = addr;

		if (batch_idx == EAGER_BATCH_SIZE) {
			/* Send all requests in batch */
			for (int i = 0; i < batch_idx; i++) {
				if (send(tcp_fd, &batch[i], sizeof(uint64_t), 0) != sizeof(uint64_t)) {
					perror("eager send");
					goto done;
				}
			}
			/* Receive and install */
			for (int i = 0; i < batch_idx; i++) {
				if (recv_exact(tcp_fd, page_buf, PAGE_SIZE) < 0)
					goto done;
				if (install_page(ctx->uffd, batch[i], page_buf) == 0) {
					hashset_insert(ctx->served, batch[i]);
					total_installed++;
				}
			}
			batch_idx = 0;
		}
	}

	/* Flush remaining batch */
	if (batch_idx > 0) {
		for (int i = 0; i < batch_idx; i++) {
			if (send(tcp_fd, &batch[i], sizeof(uint64_t), 0) != sizeof(uint64_t)) {
				perror("eager send (flush)");
				goto done;
			}
		}
		for (int i = 0; i < batch_idx; i++) {
			if (recv_exact(tcp_fd, page_buf, PAGE_SIZE) < 0)
				goto done;
			if (install_page(ctx->uffd, batch[i], page_buf) == 0) {
				hashset_insert(ctx->served, batch[i]);
				total_installed++;
			}
		}
	}

done:
	fclose(f);
	close(tcp_fd);
	printf("Eager fetch: installed %d hot pages\n", total_installed);
	return NULL;
}

/* ── Main page-fault handling loop ────────────────────── */

static int handle_faults(int uffd, int conn_fd, int tcp_fd,
			 const struct prefetch_config *pcfg,
			 const char *hot_pages_file,
			 const char *address, int port)
{
	struct pollfd fds[2];
	struct uffd_msg msg;
	char *page;
	int restore_finished = 0;

	struct hashset served;
	struct fault_history history;
	struct prefetch_stats stats;
	pthread_t eager_tid = 0;
	struct eager_ctx ectx;
	int eager_started = 0;

	if (hashset_init(&served, 1024) < 0) {
		fprintf(stderr, "hashset_init failed\n");
		return -1;
	}

	memset(&history, 0, sizeof(history));
	memset(&stats, 0, sizeof(stats));

	if (posix_memalign((void **)&page, PAGE_SIZE, PAGE_SIZE) != 0) {
		perror("posix_memalign");
		hashset_destroy(&served);
		return -1;
	}

	setbuf(stdout, NULL);  /* Unbuffered for log visibility */

	/* Start eager fetch thread if hot pages file provided */
	if (hot_pages_file) {
		ectx.uffd = uffd;
		ectx.address = address;
		ectx.port = port;
		ectx.hot_pages_file = hot_pages_file;
		ectx.served = &served;
		if (pthread_create(&eager_tid, NULL, eager_fetch_thread, &ectx) == 0) {
			eager_started = 1;
			printf("Started eager fetch thread\n");
		} else {
			perror("pthread_create eager fetch");
		}
	}

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
			if (got_signal)
				break;
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

			stats.total_faults++;

			/* Already served (by prefetch or eager fetch)? */
			if (hashset_contains(&served, page_addr)) {
				stats.prefetch_hits++;
				/* Still need to resolve the fault — the page is
				 * installed but uffd may still be blocking.
				 * Just do a zero-copy UFFDIO_COPY which will
				 * return EEXIST and unblock the faulter... except
				 * EEXIST means kernel already resolved it.
				 * Actually if UFFDIO_COPY was already done, the
				 * kernel auto-resolves subsequent faults on that
				 * page, so we can just continue. */
				continue;
			}

			/* Build prefetch target list */
			uint64_t targets[MAX_PREFETCH_TARGETS];
			int ntargets = 0;

			targets[ntargets++] = page_addr;  /* faulted page first */

			if (pcfg->enabled) {
				int64_t stride = detect_stride(&history);

				if (stride != 0) {
					/* Stride prefetch */
					for (int i = 1; i <= pcfg->stride_count && ntargets < MAX_PREFETCH_TARGETS; i++) {
						uint64_t candidate = page_addr + (uint64_t)(i * stride);
						candidate &= ~(PAGE_SIZE - 1UL);
						if (candidate != 0 && !hashset_contains(&served, candidate))
							targets[ntargets++] = candidate;
					}
				} else {
					/* Sequential prefetch */
					for (int i = 1; i <= pcfg->seq_count && ntargets < MAX_PREFETCH_TARGETS; i++) {
						uint64_t candidate = page_addr + (uint64_t)(i * PAGE_SIZE);
						if (!hashset_contains(&served, candidate))
							targets[ntargets++] = candidate;
					}
				}
			}

			/* Pipeline: send all, then recv all */
			if (pipeline_fetch_install(tcp_fd, uffd, targets, ntargets,
						   &served, page) < 0) {
				fprintf(stderr, "Failed to fetch page %#lx\n",
					(unsigned long)page_addr);
				/* Serve a zero page as fallback for the faulted page */
				memset(page, 0, PAGE_SIZE);
				install_page(uffd, page_addr, page);
				hashset_insert(&served, page_addr);
			}

			if (ntargets > 1)
				stats.pages_prefetched += (uint64_t)(ntargets - 1);

			history_push(&history, page_addr);

			if (stats.total_faults % 100 == 0 || stats.total_faults <= 10) {
				printf("Fault %lu: %#lx (prefetched %d)\n",
				       (unsigned long)stats.total_faults,
				       (unsigned long)page_addr,
				       ntargets - 1);
			}
		}

		/* uffd hung up */
		if (fds[0].revents & POLLHUP) {
			printf("POLLHUP on userfaultfd — done\n");
			break;
		}
	}

	/* Wait for eager fetch thread */
	if (eager_started)
		pthread_join(eager_tid, NULL);

	/* Print stats */
	uint64_t hit_rate = 0;
	if (stats.total_faults > 0)
		hit_rate = stats.prefetch_hits * 100 / stats.total_faults;
	printf("Prefetch stats: %lu faults, %lu prefetched, %lu hits (%lu%% hit rate)\n",
	       (unsigned long)stats.total_faults,
	       (unsigned long)stats.pages_prefetched,
	       (unsigned long)stats.prefetch_hits,
	       (unsigned long)hit_rate);
	printf("Total pages served: %lu\n",
	       (unsigned long)served.count);

	free(page);
	hashset_destroy(&served);
	return 0;
}

/* ── Usage / CLI ──────────────────────────────────────── */

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s --images-dir DIR --address ADDR --port PORT\n"
		"          [--prefetch-seq N] [--prefetch-stride N] [--no-prefetch]\n"
		"          [--hot-pages FILE]\n"
		"\n"
		"Custom lazy-pages daemon for CRIU restore.\n"
		"  --images-dir DIR       CRIU images directory (for socket path)\n"
		"  --address ADDR         TCP page server address\n"
		"  --port PORT            TCP page server port\n"
		"  --prefetch-seq N       Sequential pages to prefetch (default 16)\n"
		"  --prefetch-stride N    Stride-predicted pages to prefetch (default 8)\n"
		"  --no-prefetch          Disable all prefetching\n"
		"  --hot-pages FILE       Binary file of hot page addresses to eagerly fetch\n",
		prog);
}

int main(int argc, char *argv[])
{
	const char *images_dir = NULL;
	const char *address = "127.0.0.1";
	int port = 9999;
	const char *hot_pages_file = NULL;
	int opt;

	struct prefetch_config pcfg = {
		.seq_count = 16,
		.stride_count = 8,
		.enabled = 1,
	};

	static struct option long_opts[] = {
		{"images-dir",      required_argument, 0, 'd'},
		{"address",         required_argument, 0, 'a'},
		{"port",            required_argument, 0, 'p'},
		{"prefetch-seq",    required_argument, 0, 's'},
		{"prefetch-stride", required_argument, 0, 'S'},
		{"no-prefetch",     no_argument,       0, 'n'},
		{"hot-pages",       required_argument, 0, 'H'},
		{"help",            no_argument,       0, 'h'},
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
		case 's':
			pcfg.seq_count = atoi(optarg);
			break;
		case 'S':
			pcfg.stride_count = atoi(optarg);
			break;
		case 'n':
			pcfg.enabled = 0;
			break;
		case 'H':
			hot_pages_file = optarg;
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

	printf("Config: prefetch=%s seq=%d stride=%d hot_pages=%s\n",
	       pcfg.enabled ? "on" : "off",
	       pcfg.seq_count, pcfg.stride_count,
	       hot_pages_file ? hot_pages_file : "(none)");

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
	printf("Connected to page server at %s:%d\n", address, port);

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
	int rc = handle_faults(uffd, conn_fd, tcp_fd, &pcfg,
			       hot_pages_file, address, port);

	close(uffd);
	close(conn_fd);
	close(tcp_fd);

	return rc < 0 ? 1 : 0;
}

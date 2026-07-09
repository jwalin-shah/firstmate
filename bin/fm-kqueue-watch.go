// Small Go helper that watches a file via macOS kqueue NOTE_WRITE and exits
// when new data arrives (exit 0) or the timeout elapses (exit 2).
//
// Usage: fm-kqueue-watch [-t seconds] <file>
//
// Exit codes: 0 = woken by write, 1 = error, 2 = timeout.
package main

import (
	"flag"
	"fmt"
	"os"
	"syscall"
)

func main() {
	timeoutSec := flag.Int("t", 0, "timeout in seconds (0 = block indefinitely)")
	flag.Parse()
	if flag.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "usage: fm-kqueue-watch [-t seconds] <file>")
		os.Exit(2)
	}
	path := flag.Arg(0)

	fd, err := syscall.Open(path, syscall.O_RDONLY, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fm-kqueue-watch: open %s: %v\n", path, err)
		os.Exit(1)
	}
	defer syscall.Close(fd)

	kq, err := syscall.Kqueue()
	if err != nil {
		fmt.Fprintf(os.Stderr, "fm-kqueue-watch: kqueue: %v\n", err)
		os.Exit(1)
	}
	defer syscall.Close(kq)

	ch := syscall.Kevent_t{
		Ident:  uint64(fd),
		Filter: syscall.EVFILT_VNODE,
		Flags:  syscall.EV_ADD | syscall.EV_CLEAR,
		Fflags: syscall.NOTE_WRITE,
	}
	// Seek to end so we only see new writes.
	syscall.Seek(fd, 0, 2)

	var ts *syscall.Timespec
	if *timeoutSec > 0 {
		t := syscall.NsecToTimespec(int64(*timeoutSec) * 1_000_000_000)
		ts = &t
	}

	events := make([]syscall.Kevent_t, 1)
	for {
		n, err := syscall.Kevent(kq, []syscall.Kevent_t{ch}, events, ts)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			fmt.Fprintf(os.Stderr, "fm-kqueue-watch: kevent: %v\n", err)
			os.Exit(1)
		}
		if n == 0 {
			os.Exit(2) // timeout
		}
		if events[0].Flags&syscall.EV_EOF != 0 {
			// File was deleted/truncated - re-open and re-arm.
			syscall.Close(fd)
			fd, err = syscall.Open(path, syscall.O_RDONLY, 0)
			if err != nil {
				fmt.Fprintf(os.Stderr, "fm-kqueue-watch: re-open %s: %v\n", path, err)
				os.Exit(1)
			}
			ch.Ident = uint64(fd)
			syscall.Seek(fd, 0, 2)
			continue
		}
		// Read new data.
		var buf [4096]byte
		_, err = syscall.Read(fd, buf[:])
		if err != nil {
			fmt.Fprintf(os.Stderr, "fm-kqueue-watch: read: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}
}

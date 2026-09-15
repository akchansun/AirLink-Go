//go:build linux

package engine

import (
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func controlUDPSocket(_, _ string, c syscall.RawConn) error {
	var err error
	if e := c.Control(func(fd uintptr) {
		nfd := int(fd)
		_ = unix.SetsockoptInt(nfd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
		_ = unix.SetsockoptInt(nfd, unix.SOL_SOCKET, unix.SO_REUSEPORT, 1)
		err = unix.SetsockoptInt(nfd, unix.SOL_SOCKET, unix.SO_BROADCAST, 1)
	}); e != nil {
		return e
	}
	return err
}

func setBroadcastConn(uc *net.UDPConn) error {
	raw, err := uc.SyscallConn()
	if err != nil {
		return err
	}
	return controlUDPSocket("", "", raw)
}

func joinMulticastOn(uc *net.UDPConn, ifaceIP net.IP) {
	raw, err := uc.SyscallConn()
	if err != nil {
		return
	}
	ip4 := net.IPv4zero.To4()
	if parsed := ifaceIP.To4(); parsed != nil {
		ip4 = parsed
	}
	var mreq unix.IPMreq
	copy(mreq.Multiaddr[:], net.ParseIP(multicastGroup).To4())
	copy(mreq.Interface[:], ip4)
	_ = raw.Control(func(fd uintptr) {
		nfd := int(fd)
		_ = unix.SetsockoptIPMreq(nfd, unix.IPPROTO_IP, unix.IP_ADD_MEMBERSHIP, &mreq)
		_ = unix.SetsockoptInt(nfd, unix.IPPROTO_IP, unix.IP_MULTICAST_TTL, 2)
		_ = unix.SetsockoptInt(nfd, unix.IPPROTO_IP, unix.IP_MULTICAST_LOOP, 0)
	})
}

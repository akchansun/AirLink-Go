//go:build darwin

package engine

import (
	"net"
	"syscall"
)

func controlUDPSocket(_, _ string, c syscall.RawConn) error {
	var err error
	if e := c.Control(func(fd uintptr) {
		nfd := int(fd)
		_ = syscall.SetsockoptInt(nfd, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		_ = syscall.SetsockoptInt(nfd, syscall.SOL_SOCKET, syscall.SO_REUSEPORT, 1)
		err = syscall.SetsockoptInt(nfd, syscall.SOL_SOCKET, syscall.SO_BROADCAST, 1)
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
	var mreq syscall.IPMreq
	copy(mreq.Multiaddr[:], net.ParseIP(multicastGroup).To4())
	copy(mreq.Interface[:], ip4)
	_ = raw.Control(func(fd uintptr) {
		nfd := int(fd)
		_ = syscall.SetsockoptIPMreq(nfd, syscall.IPPROTO_IP, syscall.IP_ADD_MEMBERSHIP, &mreq)
		_ = syscall.SetsockoptInt(nfd, syscall.IPPROTO_IP, syscall.IP_MULTICAST_TTL, 2)
		_ = syscall.SetsockoptInt(nfd, syscall.IPPROTO_IP, syscall.IP_MULTICAST_LOOP, 0)
	})
}

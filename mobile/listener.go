package mobile

import (
	"io"
	"net"
	"sync"
)

// SSH channels have no deadline support. net/http also uses a temporary expired
// read deadline during Hijack, so closing the channel on deadline is incorrect.
// A net.Pipe supplies real, resettable deadlines with bounded streaming buffers.
type forwardedConn struct {
	net.Conn
	bridge  net.Conn
	channel net.Conn
	once    sync.Once
	release func()
}

func forward(channel net.Conn, release func()) *forwardedConn {
	application, bridge := net.Pipe()
	c := &forwardedConn{Conn: application, bridge: bridge, channel: channel, release: release}
	go func() { _, _ = io.Copy(bridge, channel); c.Close() }()
	go func() { _, _ = io.Copy(channel, bridge); c.Close() }()
	return c
}

func (c *forwardedConn) Close() error {
	c.once.Do(func() {
		c.Conn.Close()
		c.bridge.Close()
		c.channel.Close()
		c.release()
	})
	return nil
}

type boundedListener struct {
	net.Listener
	slots chan struct{}
}

func (l *boundedListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
			return forward(c, func() { <-l.slots }), nil
		default:
			c.Close()
		}
	}
}

package mobile

import (
	"bufio"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// Like ssh.chanConn, the underlying connection rejects deadline calls.
type noDeadlines struct{ net.Conn }

func (noDeadlines) SetDeadline(time.Time) error      { return errors.New("unsupported") }
func (noDeadlines) SetReadDeadline(time.Time) error  { return errors.New("unsupported") }
func (noDeadlines) SetWriteDeadline(time.Time) error { return errors.New("unsupported") }

func TestSSHStyleStreamDeadlinesCanBeReset(t *testing.T) {
	for _, direction := range []string{"read", "write"} {
		t.Run(direction, func(t *testing.T) {
			a, b := net.Pipe()
			defer b.Close()
			var released atomic.Int32
			c := forward(noDeadlines{a}, func() { released.Add(1) })
			defer c.Close()
			deadline := time.Now().Add(-time.Second)
			var err error
			if direction == "read" {
				err = c.SetReadDeadline(deadline)
			} else {
				err = c.SetWriteDeadline(deadline)
			}
			if err != nil {
				t.Fatal(err)
			}
			if direction == "read" {
				_, err = c.Read(make([]byte, 1))
			} else {
				_, err = c.Write([]byte("x"))
			}
			if e, ok := err.(net.Error); !ok || !e.Timeout() {
				t.Fatal("expected timeout", err)
			}
			if released.Load() != 0 {
				t.Fatal("temporary deadline closed channel")
			}
			if err := c.SetDeadline(time.Time{}); err != nil {
				t.Fatal(err)
			}
			go func() { _, _ = b.Write([]byte("y")) }()
			_ = c.SetReadDeadline(time.Now().Add(time.Second))
			buf := make([]byte, 1)
			if _, err := c.Read(buf); err != nil || string(buf) != "y" {
				t.Fatal("stream unusable after reset", err)
			}
			c.Close()
			if _, err := b.Read(buf); err == nil {
				t.Fatal("close did not reach channel")
			}
			c.Close()
			if released.Load() != 1 {
				t.Fatal("slot not released exactly once")
			}
			if c.SetDeadline(time.Time{}) == nil {
				t.Fatal("deadline accepted after close")
			}
		})
	}
}

func TestClearingHeaderDeadlineKeepsTunnelOpen(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	c := forward(noDeadlines{a}, func() {})
	defer c.Close()
	if err := c.SetDeadline(time.Now().Add(20 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if err := c.SetDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(40 * time.Millisecond)
	go func() { _, _ = b.Write([]byte("x")) }()
	_ = c.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 1)
	if _, err := c.Read(buf); err != nil || string(buf) != "x" {
		t.Fatal("cleared deadline still closed stream", err)
	}
}

type sshStyleListener struct{ net.Listener }

func (l sshStyleListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return noDeadlines{c}, nil
}

func TestHTTPConnectHandoffAndHeaderTimeout(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	b := &boundedListener{Listener: sshStyleListener{l}, slots: make(chan struct{}, 4)}
	server := &http.Server{ReadHeaderTimeout: 50 * time.Millisecond, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buffered, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		_, _ = buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		_ = buffered.Flush()
		_, _ = io.Copy(conn, buffered)
	})}
	defer server.Close()
	go func() { _ = server.Serve(b) }()
	client, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(2 * time.Second))
	_, _ = io.WriteString(client, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
	reader := bufio.NewReader(client)
	line, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(line, "200") {
		t.Fatal("CONNECT handoff failed", line, err)
	}
	if _, err := reader.ReadString('\n'); err != nil {
		t.Fatal(err)
	}
	_, _ = client.Write([]byte("tunnel-data"))
	buf := make([]byte, len("tunnel-data"))
	if _, err := io.ReadFull(reader, buf); err != nil || string(buf) != "tunnel-data" {
		t.Fatal("hijacked stream was closed by read cancellation", err)
	}
	client.Close()
	// An unauthenticated connection that never sends headers must still expire.
	idle, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	_ = idle.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := idle.Read(make([]byte, 1)); err == nil {
		t.Fatal("idle stream stayed open")
	} else if e, ok := err.(net.Error); ok && e.Timeout() {
		t.Fatal("HTTP header timeout was not enforced")
	}
}

func TestListenerBoundsUnauthenticatedConnections(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	b := &boundedListener{Listener: l, slots: make(chan struct{}, 1)}
	first, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	accepted, err := b.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, _ := b.Accept()
		if conn != nil {
			conn.Close()
		}
	}()
	second, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	_ = second.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := second.Read(make([]byte, 1)); err == nil {
		t.Fatal("extra stream remained open")
	} else if e, ok := err.(net.Error); ok && e.Timeout() {
		t.Fatal("extra stream was not rejected")
	}
	accepted.Close()
	if len(b.slots) != 0 {
		t.Fatal("slot leaked")
	}
	l.Close()
	<-done
}

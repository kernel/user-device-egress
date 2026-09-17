package connectproxy

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestPublicIP(t *testing.T) {
	for _, address := range []string{"127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "192.0.2.1", "198.18.1.1", "224.0.0.1", "240.0.0.1", "::1", "::ffff:127.0.0.1", "fc00::1", "fe80::1", "64:ff9b::7f00:1", "2001:db8::1", "2002:7f00:1::"} {
		if publicIP(netip.MustParseAddr(address)) {
			t.Errorf("accepted %s", address)
		}
	}
	for _, address := range []string{"1.1.1.1", "8.8.8.8", "2606:4700:4700::1111", "::ffff:8.8.8.8"} {
		if !publicIP(netip.MustParseAddr(address)) {
			t.Errorf("rejected %s", address)
		}
	}
}

const authorization = "Basic dXNlcjpwYXNzd29yZA=="

func testProxy(ctx context.Context) *Proxy {
	return &Proxy{ctx: ctx, auth: sha256.Sum256([]byte(authorization)), hosts: map[string]bool{"allowed.test": true}, slots: make(chan struct{}, 1)}
}

func TestDeniedRequestsNeverDial(t *testing.T) {
	for _, tc := range []struct {
		name, method, target, auth string
		ips                        []netip.Addr
		status                     int
	}{
		{"missing auth", "CONNECT", "allowed.test:443", "", nil, 407},
		{"wrong auth", "CONNECT", "allowed.test:443", "Basic " + base64.StdEncoding.EncodeToString([]byte("other:tenant")), nil, 407},
		{"host", "CONNECT", "elsewhere.test:443", authorization, nil, 403},
		{"port", "CONNECT", "allowed.test:22", authorization, nil, 403},
		{"method", "GET", "http://allowed.test/", authorization, nil, 403},
		{"private DNS", "CONNECT", "allowed.test:443", authorization, []netip.Addr{netip.MustParseAddr("127.0.0.1")}, 403},
		{"mixed DNS", "CONNECT", "allowed.test:443", authorization, []netip.Addr{netip.MustParseAddr("8.8.8.8"), netip.MustParseAddr("10.0.0.1")}, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := testProxy(context.Background())
			p.lookup = func(context.Context, string) ([]netip.Addr, error) { return tc.ips, nil }
			p.dial = func(context.Context, string, string) (net.Conn, error) {
				t.Error("dialed a denied destination")
				return nil, fmt.Errorf("denied")
			}
			r := httptest.NewRequest(tc.method, tc.target, nil)
			r.Header.Set("Proxy-Authorization", tc.auth)
			w := httptest.NewRecorder()
			p.ServeHTTP(w, r)
			if w.Code != tc.status {
				t.Fatalf("got %d, want %d", w.Code, tc.status)
			}
		})
	}
}

func TestBufferedTunnelLimitsAndCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p := testProxy(ctx)
	p.lookup = func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("8.8.8.8")}, nil
	}
	p.dial = func(_ context.Context, network, address string) (net.Conn, error) {
		if network != "tcp" || address != "8.8.8.8:443" {
			t.Errorf("dial must use validated literal IP, got %s %s", network, address)
		}
		a, b := net.Pipe()
		go func() { defer b.Close(); io.Copy(b, b) }()
		return a, nil
	}
	server := httptest.NewServer(p)
	defer server.Close()
	conn, err := net.Dial("tcp", strings.TrimPrefix(server.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(conn, "CONNECT allowed.test:443 HTTP/1.1\r\nHost: allowed.test:443\r\nProxy-Authorization: %s\r\n\r\nearly payload", authorization)
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, &http.Request{Method: "CONNECT"})
	if err != nil || response.StatusCode != 200 {
		t.Fatalf("CONNECT: %v, %v", response, err)
	}
	payload := make([]byte, len("early payload"))
	if _, err := io.ReadFull(reader, payload); err != nil || string(payload) != "early payload" {
		t.Fatalf("buffered payload lost: %q %v", payload, err)
	}
	r := httptest.NewRequest("CONNECT", "allowed.test:443", nil)
	r.Header.Set("Proxy-Authorization", authorization)
	w := httptest.NewRecorder()
	p.ServeHTTP(w, r)
	if w.Code != 503 {
		t.Fatalf("connection limit: %d", w.Code)
	}
	cancel()
	if _, err := reader.ReadByte(); err == nil {
		t.Fatal("tunnel remained open after cancellation")
	} else if e, ok := err.(net.Error); ok && e.Timeout() {
		t.Fatal("shutdown waited for timeout instead of closing")
	}
}

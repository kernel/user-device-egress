// Package connectproxy implements the bounded CONNECT handler shared by Mac and iOS.
package connectproxy

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync/atomic"
	"time"
)

type Proxy struct {
	ctx        context.Context
	auth       [32]byte
	hosts      map[string]bool
	slots      chan struct{}
	lookup     func(context.Context, string) ([]netip.Addr, error)
	dial       func(context.Context, string, string) (net.Conn, error)
	uploaded   atomic.Int64
	downloaded atomic.Int64
	active     atomic.Int64
}

type countingWriter struct {
	io.Writer
	count *atomic.Int64
}

func (w countingWriter) Write(b []byte) (int, error) {
	n, err := w.Writer.Write(b)
	w.count.Add(int64(n))
	return n, err
}

var blocked = func() []netip.Prefix {
	var prefixes []netip.Prefix
	for _, cidr := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "2001::/23", "2001:db8::/32", "2002::/16", "3fff::/20"} {
		prefixes = append(prefixes, netip.MustParsePrefix(cidr))
	}
	return prefixes
}()

func publicIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if ip.Is6() && !netip.MustParsePrefix("2000::/3").Contains(ip) {
		return false
	}
	for _, prefix := range blocked {
		if prefix.Contains(ip) {
			return false
		}
	}
	return true
}

func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	provided := sha256.Sum256([]byte(r.Header.Get("Proxy-Authorization")))
	if subtle.ConstantTimeCompare(provided[:], p.auth[:]) != 1 {
		w.Header().Set("Proxy-Authenticate", `Basic realm="mac-egress"`)
		http.Error(w, "Proxy authentication required", http.StatusProxyAuthRequired)
		return
	}
	host, port, err := net.SplitHostPort(r.Host)
	host = strings.ToLower(host)
	if r.Method != http.MethodConnect || err != nil || port != "443" || !p.hosts[host] {
		http.Error(w, "Destination or method denied", http.StatusForbidden)
		return
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	default:
		http.Error(w, "Connection limit reached", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(p.ctx, 10*time.Second)
	defer cancel()
	ips, err := p.lookup(ctx, host)
	if err != nil || len(ips) == 0 {
		http.Error(w, "DNS failed", http.StatusBadGateway)
		return
	}
	// Reject mixed public/private answers, then dial the checked literal IP.
	// There is no second hostname lookup or environment-configured upstream proxy.
	for _, ip := range ips {
		if !publicIP(ip) {
			http.Error(w, "Non-public destination denied", http.StatusForbidden)
			return
		}
	}
	var upstream net.Conn
	for _, ip := range ips {
		upstream, err = p.dial(ctx, "tcp", net.JoinHostPort(ip.Unmap().String(), port))
		if err == nil {
			break
		}
	}
	if err != nil {
		http.Error(w, "Connection failed", http.StatusBadGateway)
		return
	}
	defer upstream.Close()
	client, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer client.Close()
	p.active.Add(1)
	defer p.active.Add(-1)
	stop := context.AfterFunc(p.ctx, func() { client.Close(); upstream.Close() })
	defer stop()
	// Explicit close also works for SSH channels, which do not implement deadlines.
	timer := time.AfterFunc(2*time.Minute, func() { client.Close(); upstream.Close() })
	defer timer.Stop()
	if _, err := buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	if err := buffered.Flush(); err != nil {
		return
	}
	done := make(chan struct{})
	go func() {
		io.Copy(countingWriter{upstream, &p.uploaded}, buffered)
		upstream.Close()
		client.Close()
		close(done)
	}()
	io.Copy(countingWriter{client, &p.downloaded}, upstream)
	client.Close()
	upstream.Close()
	<-done
}

type Stats struct {
	Uploaded   int64 `json:"uploaded"`
	Downloaded int64 `json:"downloaded"`
	Active     int64 `json:"active"`
}

func (p *Proxy) Stats() Stats {
	return Stats{p.uploaded.Load(), p.downloaded.Load(), p.active.Load()}
}

func New(ctx context.Context, username, password string, hosts []string) (*Proxy, error) {
	if username == "" || len(password) < 32 {
		return nil, fmt.Errorf("invalid proxy credentials")
	}
	p := &Proxy{ctx: ctx, hosts: map[string]bool{}, slots: make(chan struct{}, 32)}
	p.auth = sha256.Sum256([]byte("Basic " + base64.StdEncoding.EncodeToString([]byte(username+":"+password))))
	for _, host := range hosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" || strings.ContainsAny(host, "/:* \t\r\n") {
			return nil, fmt.Errorf("invalid allowlist hostname")
		}
		p.hosts[host] = true
	}
	p.lookup = func(ctx context.Context, host string) ([]netip.Addr, error) {
		return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	}
	p.dial = (&net.Dialer{Timeout: 10 * time.Second}).DialContext
	return p, nil
}

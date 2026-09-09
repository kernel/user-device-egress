// mac-proxy is a bounded CONNECT-only routing spike, not a general web proxy.
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type proxy struct {
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

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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
	// The spike intentionally caps total tunnel lifetime, including idle time.
	deadline := time.Now().Add(2 * time.Minute)
	client.SetDeadline(deadline)
	upstream.SetDeadline(deadline)
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

func main() {
	listen := flag.String("listen", "127.0.0.1:18080", "Loopback listener")
	credentialFile := flag.String("credentials", "", "Private JSON credential file")
	initialize := flag.Bool("init", false, "Create fresh credentials and exit; refuses overwrite")
	allowed := flag.String("allow", "checkip.amazonaws.com,api.ipify.org", "Exact HTTPS destination hostnames")
	events := flag.Bool("events", false, "Emit non-secret JSON readiness and counters to stdout")
	parent := flag.Int("parent-pid", 0, "Stop if the owning supervisor disappears")
	flag.Parse()
	if *credentialFile == "" {
		log.Fatal("-credentials is required")
	}
	if *initialize {
		var random [32]byte
		if _, err := rand.Read(random[:]); err != nil {
			log.Fatal(err)
		}
		file, err := os.OpenFile(*credentialFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			log.Fatal(err)
		}
		defer file.Close()
		if err := json.NewEncoder(file).Encode(credentials{"session", hex.EncodeToString(random[:])}); err != nil {
			log.Fatal(err)
		}
		return
	}
	addr, err := netip.ParseAddrPort(*listen)
	if err != nil || !addr.Addr().IsLoopback() {
		log.Fatal("listener must be a literal loopback address")
	}
	data, err := os.ReadFile(*credentialFile)
	if err != nil {
		log.Fatal(err)
	}
	var creds credentials
	if err := json.Unmarshal(data, &creds); err != nil || creds.Username == "" || len(creds.Password) < 32 {
		log.Fatal("invalid credentials")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if *parent > 0 {
		go func() {
			ticker := time.NewTicker(250 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if os.Getppid() != *parent {
						cancel()
						return
					}
				}
			}
		}()
	}
	p := &proxy{ctx: ctx, hosts: map[string]bool{}, slots: make(chan struct{}, 32)}
	p.auth = sha256.Sum256([]byte("Basic " + base64.StdEncoding.EncodeToString([]byte(creds.Username+":"+creds.Password))))
	for _, host := range strings.Split(*allowed, ",") {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" || strings.ContainsAny(host, "/:* \t\r\n") {
			log.Fatal("invalid allowlist hostname")
		}
		p.hosts[host] = true
	}
	p.lookup = func(ctx context.Context, host string) ([]netip.Addr, error) {
		return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	}
	p.dial = (&net.Dialer{Timeout: 10 * time.Second}).DialContext
	server := &http.Server{Addr: *listen, Handler: p, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 4096}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	if *events {
		go func() {
			encoder := json.NewEncoder(os.Stdout)
			if encoder.Encode(map[string]any{"event": "proxy_ready", "address": listener.Addr().String()}) != nil {
				cancel()
				return
			}
			ticker := time.NewTicker(time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if encoder.Encode(map[string]any{"event": "stats", "uploaded": p.uploaded.Load(), "downloaded": p.downloaded.Load(), "active": p.active.Load()}) != nil {
						cancel()
						return
					}
				}
			}
		}()
	}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Print(err)
			cancel()
		}
	}()
	fmt.Fprintln(os.Stderr, "Mac CONNECT proxy starting on", *listen)
	<-ctx.Done()
	server.Close()
}

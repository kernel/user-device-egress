// mac-proxy is a bounded CONNECT-only routing spike, not a general web proxy.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"mac-egress-relay/internal/connectproxy"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
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
	p, err := connectproxy.New(ctx, creds.Username, creds.Password, strings.Split(*allowed, ","))
	if err != nil {
		log.Fatal(err)
	}
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
					if encoder.Encode(map[string]any{"event": "stats", "uploaded": p.Stats().Uploaded, "downloaded": p.Stats().Downloaded, "active": p.Stats().Active}) != nil {
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

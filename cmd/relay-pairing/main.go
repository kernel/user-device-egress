// relay-pairing is an unprivileged HTTP adapter. Only a fixed sudo command can
// redeem invitations; this service cannot issue them or choose tenant ports.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os/exec"
	"time"
)

type response struct {
	Status int             `json:"status"`
	Body   json.RawMessage `json:"body"`
}

func handler(redeem func(context.Context, []byte) ([]byte, error)) http.Handler {
	slots := make(chan struct{}, 4)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost || r.URL.RequestURI() != "/v1/pair" {
			http.Error(w, "Not found", 404)
			return
		}
		select {
		case slots <- struct{}{}:
			defer func() { <-slots }()
		default:
			http.Error(w, "Busy", 429)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		body, err := io.ReadAll(r.Body)
		if err != nil || !json.Valid(body) {
			http.Error(w, "Invalid request", 400)
			return
		}
		// Client disconnect must not kill an enrollment halfway through. The root
		// journal makes a lost response retryable for the same device key.
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		out, err := redeem(ctx, body)
		var result response
		if err != nil || json.Unmarshal(out, &result) != nil || result.Status < 200 || result.Status > 599 {
			http.Error(w, "Pairing failed; retry the same code or contact the relay administrator", 503)
			return
		}
		w.WriteHeader(result.Status)
		_, _ = w.Write(result.Body)
	})
}

func main() {
	server := &http.Server{Addr: "127.0.0.1:19998", ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 10 * time.Second, WriteTimeout: 50 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 4096,
		Handler: handler(func(ctx context.Context, body []byte) ([]byte, error) {
			cmd := exec.CommandContext(ctx, "/usr/bin/sudo", "-n", "/usr/local/sbin/relay-pair", "redeem")
			cmd.Stdin = bytes.NewReader(body)
			return cmd.Output()
		})}
	log.Fatal(server.ListenAndServe())
}

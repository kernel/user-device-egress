package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPairingHTTPBoundary(t *testing.T) {
	called := 0
	h := handler(func(ctx context.Context, body []byte) ([]byte, error) {
		called++
		return []byte(`{"status":409,"body":{"error":"already paired"}}`), nil
	})
	for _, tt := range []struct {
		method, path, body string
		status             int
	}{
		{"GET", "/v1/pair", "", 404},
		{"POST", "/v1/pair?token=secret", `{}`, 404},
		{"POST", "/issue", `{}`, 404},
		{"POST", "/v1/pair", "invalid", 400},
		{"POST", "/v1/pair", strings.Repeat(" ", 4097), 400},
		{"POST", "/v1/pair", `{}`, 409},
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(tt.method, tt.path, strings.NewReader(tt.body)))
		if w.Code != tt.status {
			t.Fatalf("%s: got %d", tt.path, w.Code)
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("cacheable response")
		}
	}
	if called != 1 {
		t.Fatal("invalid request reached privileged helper")
	}
}

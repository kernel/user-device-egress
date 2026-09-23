package mobile

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"golang.org/x/crypto/ssh"
)

func TestExpediaPolicyIsOptInAndStillRejectsOtherHosts(t *testing.T) {
	m, key := testManifest(t)
	standard, err := NewSession(manifestJSON(t, m), key)
	if err != nil {
		t.Fatal(err)
	}
	defer standard.Stop()
	expedia, err := NewExpediaSession(manifestJSON(t, m), key)
	if err != nil {
		t.Fatal(err)
	}
	defer expedia.Stop()
	for _, tc := range []struct {
		session *Session
		target  string
	}{
		{standard, "www.expedia.com:443"},
		{expedia, "www.expedia.com.attacker.test:443"},
		{expedia, "arbitrary.expedia.com:443"},
		{expedia, "www.expedia.com:80"},
		{expedia, "127.0.0.1:443"},
		{expedia, "example.com:443"},
	} {
		r := httptest.NewRequest("CONNECT", tc.target, nil)
		r.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte("session:"+tc.session.password)))
		w := httptest.NewRecorder()
		tc.session.proxy.ServeHTTP(w, r)
		if w.Code != http.StatusForbidden {
			t.Fatalf("%s: got %d", tc.target, w.Code)
		}
	}
}

func testManifest(t *testing.T) (manifest, string) {
	t.Helper()
	key, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	public, err := PublicKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return manifest{Tenant: "phone", IP: "1.1.1.1", Port: 20008, SSHPort: 40008, TunnelPort: 30008, SSHUser: "relay_phone", HostKey: strings.TrimSpace(public)}, key
}

func manifestJSON(t *testing.T, m manifest) string {
	t.Helper()
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestKeyAndManifest(t *testing.T) {
	m, private := testManifest(t)
	signer, err := ssh.ParsePrivateKey([]byte(private))
	if err != nil || signer.PublicKey().Type() != ssh.KeyAlgoED25519 {
		t.Fatal("invalid generated key")
	}
	if err := ValidateManifest(manifestJSON(t, m)); err != nil {
		t.Fatal(err)
	}
	if _, err := PublicKey("not a key"); err == nil {
		t.Fatal("accepted invalid key")
	}
	for name, change := range map[string]func(*manifest){
		"private relay":    func(m *manifest) { m.IP = "192.168.1.1" },
		"loopback relay":   func(m *manifest) { m.IP = "127.0.0.1" },
		"tenant traversal": func(m *manifest) { m.Tenant = "../phone" },
		"wrong user":       func(m *manifest) { m.SSHUser = "root" },
		"wrong SSH port":   func(m *manifest) { m.SSHPort++ },
		"wrong forward":    func(m *manifest) { m.TunnelPort++ },
		"missing pin":      func(m *manifest) { m.HostKey = "" },
		"multiple pins":    func(m *manifest) { m.HostKey += "\n" + m.HostKey },
		"key options":      func(m *manifest) { m.HostKey = "restrict " + m.HostKey },
	} {
		t.Run(name, func(t *testing.T) {
			invalid := m
			change(&invalid)
			if ValidateManifest(manifestJSON(t, invalid)) == nil {
				t.Fatal("accepted invalid enrollment")
			}
		})
	}
	if ValidateManifest(strings.Repeat(" ", 16385)) == nil {
		t.Fatal("accepted oversized enrollment")
	}
}

func TestSessionStopCredentialsAndRedaction(t *testing.T) {
	m, key := testManifest(t)
	one, err := NewSession(manifestJSON(t, m), key)
	if err != nil {
		t.Fatal(err)
	}
	two, err := NewSession(manifestJSON(t, m), key)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Stop()
	if one.password == two.password || len(one.password) != 64 {
		t.Fatal("session credentials not fresh")
	}
	if strings.Contains(one.Snapshot(), one.password) || strings.Contains(one.Snapshot(), key) {
		t.Fatal("snapshot exposed secrets")
	}
	if _, err := one.DirectIP("localhost"); err == nil {
		t.Fatal("accepted non-demo IP host")
	}
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() { one.Stop(); _ = one.Snapshot() })
	}
	wg.Wait()
	if one.Start() == nil {
		t.Fatal("stopped session restarted")
	}
	if !strings.Contains(one.Snapshot(), `"state":"stopped"`) {
		t.Fatal("stop state lost")
	}
}

// Package mobile is the in-process iOS networking bridge. It never launches helpers.
package mobile

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"mac-egress-relay/internal/connectproxy"
)

var hosts = []string{"checkip.amazonaws.com", "api.ipify.org", "public-ping-bucket-kernel.s3.us-east-1.amazonaws.com"}

type manifest struct {
	Tenant     string `json:"tenant"`
	IP         string `json:"ip"`
	Port       int    `json:"port"`
	SSHPort    int    `json:"ssh_port"`
	TunnelPort int    `json:"tunnel_port"`
	SSHUser    string `json:"ssh_user"`
	HostKey    string `json:"host_key"`
}

func parseManifest(raw string) (manifest, ssh.PublicKey, error) {
	var m manifest
	if len(raw) > 16384 || json.Unmarshal([]byte(raw), &m) != nil {
		return m, nil, errors.New("Invalid enrollment JSON")
	}
	ip, err := netip.ParseAddr(m.IP)
	if err != nil || !ip.Is4() || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || !regexp.MustCompile(`^[a-z][a-z0-9]{0,19}$`).MatchString(m.Tenant) || m.SSHUser != "relay_"+m.Tenant || m.Port < 20000 || m.Port > 29999 || m.TunnelPort != m.Port+10000 || m.SSHPort != m.Port+20000 {
		return m, nil, errors.New("Invalid relay address, tenant, or port mapping")
	}
	key, _, options, rest, err := ssh.ParseAuthorizedKey([]byte(m.HostKey))
	if err != nil || len(options) != 0 || len(rest) != 0 || strings.ContainsAny(m.HostKey, "\r\n") || key.Type() != ssh.KeyAlgoED25519 {
		return m, nil, errors.New("Invalid pinned SSH host key")
	}
	return m, key, nil
}

// ValidateManifest checks enrollment before it is stored on the device.
func ValidateManifest(raw string) error { _, _, err := parseManifest(raw); return err }

// GenerateKey returns a PKCS8 private key. The Swift caller stores it only in Keychain.
func GenerateKey() (string, error) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", err
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return "", err
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), nil
}

func PublicKey(privateKey string) (string, error) {
	key, err := ssh.ParsePrivateKey([]byte(privateKey))
	if err != nil {
		return "", errors.New("Invalid device key")
	}
	return string(ssh.MarshalAuthorizedKey(key.PublicKey())), nil
}

// Session is single-use. Stop is safe during startup and closes every owned stream.
type Session struct {
	mu       sync.Mutex
	ctx      context.Context
	cancel   context.CancelFunc
	manifest manifest
	signer   ssh.Signer
	hostKey  ssh.PublicKey
	password string
	proxy    *connectproxy.Proxy
	state    string
	message  string
	ip       string
	started  bool
}

func NewSession(enrollment, privateKey string) (*Session, error) {
	m, pin, err := parseManifest(enrollment)
	if err != nil {
		return nil, err
	}
	signer, err := ssh.ParsePrivateKey([]byte(privateKey))
	if err != nil {
		return nil, errors.New("Invalid device private key")
	}
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	s := &Session{ctx: ctx, cancel: cancel, manifest: m, signer: signer, hostKey: pin, password: hex.EncodeToString(random[:]), state: "ready"}
	s.proxy, err = connectproxy.New(ctx, "session", s.password, hosts)
	if err != nil {
		cancel()
		return nil, err
	}
	return s, nil
}

func (s *Session) fail(message string) {
	s.mu.Lock()
	if s.state != "stopped" {
		s.state = "failed"
		s.message = message
	}
	s.mu.Unlock()
	s.cancel()
}

func (s *Session) Stop() {
	s.mu.Lock()
	s.state = "stopped"
	s.mu.Unlock()
	s.cancel()
}

func (s *Session) Snapshot() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, _ := json.Marshal(struct {
		State   string             `json:"state"`
		Message string             `json:"message"`
		IP      string             `json:"ip"`
		Stats   connectproxy.Stats `json:"stats"`
	}{s.state, s.message, s.ip, s.proxy.Stats()})
	return string(b)
}

// ProxyConfig contains short-lived credentials. Never log this return value.
func (s *Session) ProxyConfig() string {
	b, _ := json.Marshal(map[string]any{"host": s.manifest.IP, "port": s.manifest.Port, "username": "session", "password": s.password})
	return string(b)
}

// Start blocks until the reverse tunnel and its HTTPS route have been verified.
// Swift invokes this off its main actor. Stop can cancel it at any point.
func (s *Session) Start() error {
	s.mu.Lock()
	if s.started || s.ctx.Err() != nil {
		s.mu.Unlock()
		return errors.New("Session already used; start a new demo")
	}
	s.started = true
	s.state = "connecting"
	s.mu.Unlock()
	if err := s.start(); err != nil {
		s.fail(err.Error())
		return err
	}
	return nil
}

func (s *Session) start() error {
	address := net.JoinHostPort(s.manifest.IP, fmt.Sprint(s.manifest.SSHPort))
	conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(s.ctx, "tcp", address)
	if err != nil {
		return errors.New("Cannot reach the relay SSH port. Check enrollment and network access")
	}
	context.AfterFunc(s.ctx, func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	cc, chans, requests, err := ssh.NewClientConn(conn, address, &ssh.ClientConfig{
		User: s.manifest.SSHUser, Auth: []ssh.AuthMethod{ssh.PublicKeys(s.signer)}, HostKeyCallback: ssh.FixedHostKey(s.hostKey),
	})
	if err != nil {
		conn.Close()
		return errors.New("SSH authentication or pinned host-key verification failed. Enroll this phone's public key")
	}
	conn.SetDeadline(time.Time{})
	client := ssh.NewClient(cc, chans, requests)
	context.AfterFunc(s.ctx, func() { client.Close() })
	go func() {
		_ = client.Wait()
		if s.ctx.Err() == nil {
			s.fail("Relay tunnel disconnected")
		}
	}()
	listener, err := client.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", s.manifest.TunnelPort))
	if err != nil {
		return errors.New("Relay refused forwarding. Check enrollment or stop the other session for this device")
	}
	server := &http.Server{Handler: s.proxy, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 4096}
	bounded := &boundedListener{Listener: listener, slots: make(chan struct{}, 64)}
	context.AfterFunc(s.ctx, func() { server.Close(); listener.Close() })
	go func() {
		if err := server.Serve(bounded); err != nil && s.ctx.Err() == nil {
			s.fail("Proxy listener stopped")
		}
	}()
	go s.keepalive(client)
	s.mu.Lock()
	s.state = "verifying"
	s.mu.Unlock()
	direct, err := s.DirectIP("checkip.amazonaws.com")
	if err != nil {
		return err
	}
	relayed, err := s.checkIP("checkip.amazonaws.com", true)
	if err != nil {
		return err
	}
	if direct != relayed {
		return errors.New("Relay IP does not match this device. Demo stopped")
	}
	s.mu.Lock()
	if s.ctx.Err() != nil {
		s.mu.Unlock()
		return errors.New("Demo stopped")
	}
	s.ip = direct
	s.state = "sharing"
	s.mu.Unlock()
	go s.monitorRoute(direct)
	return nil
}

func (s *Session) keepalive(client *ssh.Client) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			reply := make(chan error, 1)
			go func() { _, _, err := client.SendRequest("keepalive@openssh.com", true, nil); reply <- err }()
			select {
			case err := <-reply:
				if err != nil {
					s.fail("SSH keepalive failed")
					return
				}
			case <-time.After(10 * time.Second):
				s.fail("SSH keepalive timed out")
				return
			case <-s.ctx.Done():
				return
			}
		}
	}
}

func (s *Session) monitorRoute(initial string) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			if errors.Is(s.ctx.Err(), context.DeadlineExceeded) {
				s.fail("Ten-minute demo limit reached")
			}
			return
		case <-ticker.C:
			direct, err := s.DirectIP("checkip.amazonaws.com")
			if err != nil || direct != initial {
				s.fail("Device connection changed. Start a new demo")
				return
			}
			relayed, err := s.checkIP("checkip.amazonaws.com", true)
			if err != nil || relayed != initial {
				s.fail("Relay route could no longer be verified")
				return
			}
		}
	}
}

func (s *Session) DirectIP(host string) (string, error) { return s.checkIP(host, false) }

func (s *Session) checkIP(host string, throughRelay bool) (string, error) {
	if host != "checkip.amazonaws.com" && host != "api.ipify.org" {
		return "", errors.New("Unsupported IP-check host")
	}
	transport := &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: 8 * time.Second, DialContext: (&net.Dialer{Timeout: 8 * time.Second}).DialContext}
	if throughRelay {
		transport.Proxy = http.ProxyURL(&url.URL{Scheme: "https", Host: net.JoinHostPort(s.manifest.IP, fmt.Sprint(s.manifest.Port)), User: url.UserPassword("session", s.password)})
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequestWithContext(s.ctx, "GET", "https://"+host+"/?egress="+fmt.Sprint(time.Now().UnixNano()), nil)
	resp, err := client.Do(req)
	if err != nil {
		return "", errors.New("IP check could not connect. Check Wi-Fi/cellular and relay TLS")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 128))
	ip, parseErr := netip.ParseAddr(strings.TrimSpace(string(data)))
	if err != nil || parseErr != nil || resp.StatusCode != 200 {
		return "", errors.New("IP service did not return an address")
	}
	return ip.Unmap().String(), nil
}

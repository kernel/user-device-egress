// mac-session owns a proxy and SSH tunnel for exactly as long as its app owns stdin.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const allowedHosts = "checkip.amazonaws.com,api.ipify.org,public-ping-bucket-kernel.s3.us-east-1.amazonaws.com"

type manifest struct {
	Tenant     string `json:"tenant"`
	IP         string `json:"ip"`
	Port       int    `json:"port"`
	SSHPort    int    `json:"ssh_port"`
	TunnelPort int    `json:"tunnel_port"`
	SSHUser    string `json:"ssh_user"`
	HostKey    string `json:"host_key"`
}

type connection struct {
	Manifest   manifest `json:"manifest"`
	PrivateKey string   `json:"private_key"`
}

func (m manifest) validate() error {
	ip, err := netip.ParseAddr(m.IP)
	if err != nil || !ip.Is4() || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return errors.New("relay must have a public IPv4 address")
	}
	if !regexp.MustCompile(`^[a-z][a-z0-9]{0,19}$`).MatchString(m.Tenant) || m.SSHUser != "relay_"+m.Tenant || m.Port < 20000 || m.Port > 29999 || m.SSHPort != m.Port+20000 || m.TunnelPort != m.Port+10000 {
		return errors.New("invalid tenant port or identity mapping")
	}
	key := strings.Fields(m.HostKey)
	if len(key) < 2 || key[0] != "ssh-ed25519" || strings.ContainsAny(m.HostKey, "\r\n") {
		return errors.New("invalid pinned host key")
	}
	decoded, err := base64.StdEncoding.DecodeString(key[1])
	if err != nil || len(decoded) != 51 {
		return errors.New("invalid pinned host key")
	}
	return nil
}

type events struct{ mu sync.Mutex }

func (e *events) send(value map[string]any) {
	e.mu.Lock()
	defer e.mu.Unlock()
	_ = json.NewEncoder(os.Stdout).Encode(value)
}

func ipCheck(ctx context.Context, proxyURL *url.URL) (string, error) {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{DisableKeepAlives: true, TLSHandshakeTimeout: 5 * time.Second,
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			return dialer.DialContext(ctx, "tcp4", address)
		}}
	if proxyURL != nil {
		transport.Proxy = http.ProxyURL(proxyURL)
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://checkip.amazonaws.com/", nil)
	resp, err := client.Do(req)
	if err != nil {
		return "", errors.New("IP verification could not connect")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 128))
	if err != nil || resp.StatusCode != 200 {
		return "", errors.New("IP verification returned an error")
	}
	ip, err := netip.ParseAddr(strings.TrimSpace(string(data)))
	if err != nil || !ip.Is4() {
		return "", errors.New("IP service did not return IPv4")
	}
	return ip.String(), nil
}

func stopProcess(cmd *exec.Cmd, done <-chan error) {
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}

func run(ctx context.Context, cancel context.CancelFunc, input *bufio.Reader, root, proxyPath string, output *events) error {
	line, err := input.ReadBytes('\n')
	if err != nil || len(line) > 32768 {
		return errors.New("missing device connection")
	}
	var device connection
	if json.Unmarshal(line, &device) != nil {
		return errors.New("invalid device connection")
	}
	if err := device.Manifest.validate(); err != nil {
		return err
	}
	if !strings.HasPrefix(device.PrivateKey, "-----BEGIN OPENSSH PRIVATE KEY-----\n") || len(device.PrivateKey) > 16384 {
		return errors.New("expected an OpenSSH device key")
	}
	// EOF is also delivered when the app crashes or is force-quit. Children do not inherit this pipe.
	go func() { _, _ = io.Copy(io.Discard, input); cancel() }()
	directory, err := os.MkdirTemp(root, "session-")
	if err != nil {
		return errors.New("could not create private session directory")
	}
	defer os.RemoveAll(directory) // Exactly the directory created above, never a caller-supplied tree.
	write := func(name string, data []byte) error { return os.WriteFile(filepath.Join(directory, name), data, 0600) }
	keyPath := filepath.Join(directory, "device")
	if err := write("device", []byte(device.PrivateKey)); err != nil {
		return err
	}
	// Validate the private key before attempting SSH. Batch mode avoids passphrase prompts.
	validate := exec.CommandContext(ctx, "/usr/bin/ssh-keygen", "-y", "-P", "", "-f", keyPath)
	if err := validate.Run(); err != nil {
		return errors.New("device key must be valid and have no passphrase; it is stored in Keychain")
	}
	m := device.Manifest
	manifestJSON, _ := json.Marshal(m)
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}
	password := hex.EncodeToString(random[:])
	creds, _ := json.Marshal(map[string]string{"username": "session", "password": password})
	proxyURL := &url.URL{Scheme: "https", Host: net.JoinHostPort(m.IP, strconv.Itoa(m.Port)), User: url.UserPassword("session", password)}
	files := map[string][]byte{
		"manifest.json": manifestJSON, "credentials.json": creds,
		"known_hosts": []byte(fmt.Sprintf("[%s]:%d %s\n", m.IP, m.SSHPort, m.HostKey)),
		"curl.conf":   []byte(fmt.Sprintf("proxy = \"https://%s:%d\"\nproxy-user = \"session:%s\"\nnoproxy = \"\"\n", m.IP, m.Port, password)),
	}
	for name, data := range files {
		if err := write(name, data); err != nil {
			return err
		}
	}
	proxy := exec.Command(proxyPath, "-listen", "127.0.0.1:0", "-credentials", filepath.Join(directory, "credentials.json"), "-allow", allowedHosts, "-events", "-parent-pid", strconv.Itoa(os.Getpid()))
	pipe, err := proxy.StdoutPipe()
	if err != nil {
		return err
	}
	if err := proxy.Start(); err != nil {
		return errors.New("could not launch bundled proxy")
	}
	proxyDone := make(chan error, 1)
	go func() { proxyDone <- proxy.Wait(); cancel() }()
	defer stopProcess(proxy, proxyDone)
	ready := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(pipe)
		for scanner.Scan() {
			var event map[string]any
			if json.Unmarshal(scanner.Bytes(), &event) != nil {
				cancel()
				return
			}
			if event["event"] == "proxy_ready" {
				address, _ := event["address"].(string)
				select {
				case ready <- address:
				default:
				}
			} else {
				output.send(event)
			}
		}
	}()
	var address string
	select {
	case address = <-ready:
	case <-ctx.Done():
		return errors.New("proxy stopped before becoming ready")
	case <-time.After(5 * time.Second):
		return errors.New("proxy startup timed out")
	}
	ssh := exec.Command("/usr/bin/ssh", "-F", "/dev/null", "-N", "-i", keyPath, "-p", strconv.Itoa(m.SSHPort),
		"-o", "UserKnownHostsFile="+strconv.Quote(filepath.Join(directory, "known_hosts")), "-o", "GlobalKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
		"-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
		"-R", fmt.Sprintf("127.0.0.1:%d:%s", m.TunnelPort, address), m.SSHUser+"@"+m.IP)
	if err := ssh.Start(); err != nil {
		return errors.New("could not launch SSH tunnel")
	}
	sshDone := make(chan error, 1)
	go func() { sshDone <- ssh.Wait(); cancel() }()
	defer stopProcess(ssh, sshDone)
	output.send(map[string]any{"event": "verifying", "directory": directory})
	// Retry only while starting, when the SSH forwarding listener may not exist yet.
	deadline := time.Now().Add(35 * time.Second)
	var verified string
	for {
		direct, directErr := ipCheck(ctx, nil)
		relayed, relayErr := ipCheck(ctx, proxyURL)
		if directErr == nil && relayErr == nil {
			if direct != relayed {
				return errors.New("relay exit IP does not match this Mac; sharing stopped")
			}
			verified = direct
			break
		}
		if ctx.Err() != nil {
			return errors.New("tunnel or proxy stopped; check enrollment and connectivity")
		}
		if time.Now().After(deadline) {
			return errors.New("route verification failed; check relay reachability and enrollment")
		}
		select {
		case <-ctx.Done():
			return errors.New("sharing stopped")
		case <-time.After(time.Second):
		}
	}
	output.send(map[string]any{"event": "sharing", "ip": verified, "directory": directory})
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return errors.New("tunnel or proxy disconnected; sharing stopped")
		case <-ticker.C:
			direct, err := ipCheck(ctx, nil)
			if err != nil {
				return errors.New("connection verification failed; sharing stopped")
			}
			relayed, err := ipCheck(ctx, proxyURL)
			if err != nil || direct != verified || relayed != verified {
				return errors.New("connection or exit IP changed; start again to verify the new route")
			}
			output.send(map[string]any{"event": "sharing", "ip": verified, "directory": directory})
		}
	}
}

func main() {
	root := flag.String("sessions", "", "Existing private parent directory")
	proxy := flag.String("proxy", "", "Bundled mac-proxy executable")
	flag.Parse()
	// The app can kill this entire group if this supervisor itself crashes.
	if syscall.Setpgid(0, 0) != nil {
		os.Exit(1)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	output := &events{}
	err := run(ctx, cancel, bufio.NewReader(io.LimitReader(os.Stdin, 1<<20)), *root, *proxy, output)
	if err != nil {
		output.send(map[string]any{"event": "error", "message": err.Error()})
	}
}

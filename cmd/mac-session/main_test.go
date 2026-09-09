package main

import (
	"encoding/base64"
	"os/exec"
	"testing"
	"time"
)

func testManifest() manifest {
	return manifest{Tenant: "device", IP: "192.0.2.20", Port: 20000, SSHPort: 40000, TunnelPort: 30000,
		SSHUser: "relay_device", HostKey: "ssh-ed25519 " + base64.StdEncoding.EncodeToString(make([]byte, 51))}
}

func TestManifestValidation(t *testing.T) {
	valid := testManifest()
	if err := valid.validate(); err != nil {
		t.Fatal(err)
	}
	withComment := valid
	withComment.HostKey += " operator@relay"
	if err := withComment.validate(); err != nil {
		t.Fatal("valid SSH comment rejected:", err)
	}
	for name, mutate := range map[string]func(*manifest){
		"private relay":      func(m *manifest) { m.IP = "192.168.1.1" },
		"loopback relay":     func(m *manifest) { m.IP = "127.0.0.1" },
		"ipv6 relay":         func(m *manifest) { m.IP = "::1" },
		"wrong user":         func(m *manifest) { m.SSHUser = "root" },
		"wrong backend":      func(m *manifest) { m.TunnelPort++ },
		"wrong SSH port":     func(m *manifest) { m.SSHPort++ },
		"SSH injection":      func(m *manifest) { m.Tenant = "device\nProxyCommand=bad" },
		"host key injection": func(m *manifest) { m.HostKey += "\nother-host key" },
		"bad host key":       func(m *manifest) { m.HostKey = "ssh-ed25519 garbage" },
	} {
		t.Run(name, func(t *testing.T) {
			m := valid
			mutate(&m)
			if m.validate() == nil {
				t.Fatal("accepted unsafe manifest")
			}
		})
	}
}

func TestStopProcessReapsChild(t *testing.T) {
	cmd := exec.Command("/bin/sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	start := time.Now()
	stopProcess(cmd, done)
	if cmd.ProcessState == nil {
		t.Fatal("child not reaped")
	}
	if time.Since(start) > 3*time.Second {
		t.Fatal("shutdown too slow")
	}
}

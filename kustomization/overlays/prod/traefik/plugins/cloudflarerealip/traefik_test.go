//go:build traefik

package cloudflarerealip_test

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	moduleName   = "tswn.us/cloudflarerealip"
	readyTimeout = 30 * time.Second
	trustedPeer  = "127.0.0.2"
)

type observed struct {
	cf    string
	count int
	xff   string
	xri   string
}

type recorder struct {
	mu   sync.Mutex
	last observed
}

func (r *recorder) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	r.mu.Lock()
	r.last = observed{
		cf:    req.Header.Get("CF-Connecting-IP"),
		count: r.last.count + 1,
		xff:   req.Header.Get("X-Forwarded-For"),
		xri:   req.Header.Get("X-Real-Ip"),
	}
	r.mu.Unlock()
	rw.WriteHeader(http.StatusOK)
}

func (r *recorder) snapshot() observed {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.last
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func freeAddr(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("free port: %v", err)
	}
	defer listener.Close()
	return listener.Addr().String()
}

func copyPluginFiles(t *testing.T, dst string) {
	t.Helper()
	if err := os.MkdirAll(dst, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dst, err)
	}
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read plugin dir: %v", err)
	}
	copied := 0
	for _, entry := range entries {
		name := entry.Name()
		shipped := name == ".traefik.yml" || name == "go.mod" ||
			(strings.HasSuffix(name, ".go") && !strings.HasSuffix(name, "_test.go"))
		if entry.IsDir() || !shipped {
			continue
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if err := os.WriteFile(filepath.Join(dst, name), data, 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		copied++
	}
	if copied < 3 {
		t.Fatalf("copied %d plugin files, want .traefik.yml, go.mod and at least one .go file", copied)
	}
}

func startTraefik(t *testing.T, bin, backendURL, authURL string) (entry string, output *lockedBuffer) {
	t.Helper()
	work := t.TempDir()
	copyPluginFiles(t, filepath.Join(work, "plugins-local", "src", moduleName))

	entry = freeAddr(t)
	ping := freeAddr(t)
	static := fmt.Sprintf(`entryPoints:
  ext:
    address: %q
    http:
      middlewares:
        - cloudflare-real-ip@file
  ping:
    address: %q
experimental:
  localPlugins:
    cloudflarerealip:
      moduleName: %s
global:
  checkNewVersion: false
  sendAnonymousUsage: false
log:
  level: INFO
ping:
  entryPoint: ping
providers:
  file:
    filename: %s
`, entry, ping, moduleName, filepath.Join(work, "dynamic.yml"))
	dynamic := fmt.Sprintf(`http:
  middlewares:
    auth:
      forwardAuth:
        address: %s
        trustForwardHeader: true
    cloudflare-real-ip:
      plugin:
        cloudflarerealip:
          trustedPeers:
            - %s/32
  routers:
    all:
      entryPoints:
        - ext
      middlewares:
        - auth
      rule: PathPrefix(`+"`/`"+`)
      service: backend
  services:
    backend:
      loadBalancer:
        servers:
          - url: %s
`, authURL, trustedPeer, backendURL)
	staticPath := filepath.Join(work, "static.yml")
	for path, content := range map[string]string{staticPath: static, filepath.Join(work, "dynamic.yml"): dynamic} {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}

	output = &lockedBuffer{}
	cmd := exec.Command(bin, "--configFile="+staticPath)
	cmd.Dir = work
	cmd.Stdout = output
	cmd.Stderr = output
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %s: %v", bin, err)
	}
	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-exited
	})

	deadline := time.Now().Add(readyTimeout)
	for {
		select {
		case <-exited:
			t.Fatalf("traefik exited before it was ready; output:\n%s", output.String())
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("traefik not ready after %s; output:\n%s", readyTimeout, output.String())
		}
		resp, err := http.Get("http://" + ping + "/ping")
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return entry, output
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func clientFrom(source string) *http.Client {
	dialer := &net.Dialer{LocalAddr: &net.TCPAddr{IP: net.ParseIP(source)}, Timeout: 5 * time.Second}
	return &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext:       dialer.DialContext,
			DisableKeepAlives: true,
		},
	}
}

func TestTraefikLoadsPlugin(t *testing.T) {
	bin := os.Getenv("TRAEFIK_BIN")
	if bin == "" {
		t.Fatal("TRAEFIK_BIN is not set")
	}
	backend, auth := &recorder{}, &recorder{}
	backendServer := httptest.NewServer(backend)
	defer backendServer.Close()
	authServer := httptest.NewServer(auth)
	defer authServer.Close()

	entry, output := startTraefik(t, bin, backendServer.URL, authServer.URL)

	send := func(source string, headers map[string]string) (*http.Response, error) {
		req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, "http://"+entry+"/", nil)
		if err != nil {
			return nil, err
		}
		for key, value := range headers {
			req.Header.Set(key, value)
		}
		return clientFrom(source).Do(req)
	}

	deadline := time.Now().Add(readyTimeout)
	for backend.snapshot().count == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("backend never saw a request through traefik; output:\n%s", output.String())
		}
		if resp, err := send("127.0.0.1", nil); err == nil {
			_ = resp.Body.Close()
		}
		time.Sleep(200 * time.Millisecond)
	}

	cases := []struct {
		name    string
		source  string
		headers map[string]string
		want    observed
	}{
		{
			name:    "trusted peer replaces the forwarded address",
			source:  trustedPeer,
			headers: map[string]string{"CF-Connecting-IP": "198.51.100.7", "X-Forwarded-For": "10.117.0.33"},
			want:    observed{cf: "198.51.100.7", xff: "198.51.100.7, 127.0.0.2", xri: "198.51.100.7"},
		},
		{
			name:    "untrusted peer loses the Cloudflare header",
			source:  "127.0.0.3",
			headers: map[string]string{"CF-Connecting-IP": "198.51.100.7", "X-Forwarded-For": "10.117.0.33"},
			want:    observed{xff: "127.0.0.3", xri: "127.0.0.3"},
		},
		{
			name:    "trusted peer with a list is not believed",
			source:  trustedPeer,
			headers: map[string]string{"CF-Connecting-IP": "198.51.100.7, 203.0.113.9"},
			want:    observed{xff: "127.0.0.2", xri: "127.0.0.2"},
		},
		{
			name:   "trusted peer without the header keeps the peer address",
			source: trustedPeer,
			want:   observed{xff: "127.0.0.2", xri: "127.0.0.2"},
		},
		{
			name:    "trusted peer with an IPv6 client",
			source:  trustedPeer,
			headers: map[string]string{"CF-Connecting-IP": "2001:db8::1"},
			want:    observed{cf: "2001:db8::1", xff: "2001:db8::1, 127.0.0.2", xri: "2001:db8::1"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp, err := send(tc.source, tc.headers)
			if err != nil {
				t.Fatalf("request from %s: %v\ntraefik output:\n%s", tc.source, err, output.String())
			}
			_ = resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200\ntraefik output:\n%s", resp.StatusCode, output.String())
			}
			for name, recorded := range map[string]*recorder{"backend": backend, "forward-auth": auth} {
				got := recorded.snapshot()
				got.count = 0
				if got != tc.want {
					t.Errorf("%s saw %+v, want %+v", name, got, tc.want)
				}
			}
		})
	}
}

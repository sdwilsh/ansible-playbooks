package cloudflarerealip_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"tswn.us/cloudflarerealip"
)

const (
	choros   = "10.11.2.2:40000"
	stranger = "198.51.100.9:40000"
)

type seen struct {
	cf  string
	xff string
	xri string
}

func serve(t *testing.T, cfg *cloudflarerealip.Config, remoteAddr string, headers map[string]string) seen {
	t.Helper()
	var got seen
	next := http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
		got = seen{
			cf:  req.Header.Get("CF-Connecting-IP"),
			xff: req.Header.Get("X-Forwarded-For"),
			xri: req.Header.Get("X-Real-Ip"),
		}
	})
	handler, err := cloudflarerealip.New(context.Background(), next, cfg, "test")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	req := httptest.NewRequest(http.MethodGet, "http://example.test/", nil)
	req.RemoteAddr = remoteAddr
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	handler.ServeHTTP(httptest.NewRecorder(), req)
	return got
}

func TestServeHTTP(t *testing.T) {
	cases := []struct {
		name    string
		remote  string
		headers map[string]string
		want    seen
	}{
		{
			name:    "untrusted peer with header drops the header",
			remote:  stranger,
			headers: map[string]string{"CF-Connecting-IP": "203.0.113.7", "X-Forwarded-For": "198.51.100.9"},
			want:    seen{xff: "198.51.100.9"},
		},
		{
			name:    "untrusted peer without header leaves the request alone",
			remote:  stranger,
			headers: map[string]string{"X-Forwarded-For": "198.51.100.9", "X-Real-Ip": "198.51.100.9"},
			want:    seen{xff: "198.51.100.9", xri: "198.51.100.9"},
		},
		{
			name:    "unparseable remote address with header drops the header",
			remote:  "not-an-address",
			headers: map[string]string{"CF-Connecting-IP": "203.0.113.7"},
			want:    seen{},
		},
		{
			name:    "trusted peer with a valid address sets both headers",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "203.0.113.7"},
			want:    seen{cf: "203.0.113.7", xff: "203.0.113.7", xri: "203.0.113.7"},
		},
		{
			name:   "trusted peer replaces a forged forwarded header",
			remote: choros,
			headers: map[string]string{
				"CF-Connecting-IP": "203.0.113.7",
				"X-Forwarded-For":  "10.117.0.33",
				"X-Real-Ip":        "10.117.0.33",
			},
			want: seen{cf: "203.0.113.7", xff: "203.0.113.7", xri: "203.0.113.7"},
		},
		{
			name:    "trusted peer with spaces around the address trims them",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "  203.0.113.7 "},
			want:    seen{cf: "  203.0.113.7 ", xff: "203.0.113.7", xri: "203.0.113.7"},
		},
		{
			name:    "trusted peer without header leaves the request alone",
			remote:  choros,
			headers: map[string]string{"X-Forwarded-For": "10.11.2.2"},
			want:    seen{xff: "10.11.2.2"},
		},
		{
			name:    "trusted peer with a comma list drops the header",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "10.117.0.33, 203.0.113.7", "X-Forwarded-For": "10.11.2.2"},
			want:    seen{xff: "10.11.2.2"},
		},
		{
			name:    "trusted peer with a non-address drops the header",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "not-an-address", "X-Forwarded-For": "10.11.2.2"},
			want:    seen{xff: "10.11.2.2"},
		},
		{
			name:    "trusted peer with an empty header drops the header",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "", "X-Forwarded-For": "10.11.2.2"},
			want:    seen{xff: "10.11.2.2"},
		},
		{
			name:    "trusted peer with an IPv6 client sets both headers",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "2001:db8::7"},
			want:    seen{cf: "2001:db8::7", xff: "2001:db8::7", xri: "2001:db8::7"},
		},
		{
			name:    "trusted peer with a 4-in-6 client sets the IPv4 form",
			remote:  choros,
			headers: map[string]string{"CF-Connecting-IP": "::ffff:203.0.113.7"},
			want:    seen{cf: "::ffff:203.0.113.7", xff: "203.0.113.7", xri: "203.0.113.7"},
		},
		{
			name:    "trusted peer in 4-in-6 form is still trusted",
			remote:  "[::ffff:10.11.2.2]:40000",
			headers: map[string]string{"CF-Connecting-IP": "203.0.113.7"},
			want:    seen{cf: "203.0.113.7", xff: "203.0.113.7", xri: "203.0.113.7"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := cloudflarerealip.CreateConfig()
			cfg.TrustedPeers = []string{"10.11.2.2/32"}
			if got := serve(t, cfg, tc.remote, tc.headers); got != tc.want {
				t.Errorf("next saw %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestServeHTTPCustomHeader(t *testing.T) {
	cfg := &cloudflarerealip.Config{Header: "X-Client", TrustedPeers: []string{"10.11.0.0/16"}}
	got := serve(t, cfg, "10.11.9.9:1", map[string]string{"X-Client": "203.0.113.7"})
	if want := (seen{xff: "203.0.113.7", xri: "203.0.113.7"}); got != want {
		t.Errorf("next saw %+v, want %+v", got, want)
	}
}

func TestCreateConfigDefaultsHeader(t *testing.T) {
	if got := cloudflarerealip.CreateConfig().Header; got != "CF-Connecting-IP" {
		t.Errorf("default header = %q, want CF-Connecting-IP", got)
	}
}

func TestNewRejectsBadConfig(t *testing.T) {
	cases := []struct {
		name string
		cfg  *cloudflarerealip.Config
	}{
		{"nil trustedPeers", &cloudflarerealip.Config{Header: "CF-Connecting-IP"}},
		{"empty trustedPeers", &cloudflarerealip.Config{Header: "CF-Connecting-IP", TrustedPeers: []string{}}},
		{"bare address instead of a prefix", &cloudflarerealip.Config{Header: "CF-Connecting-IP", TrustedPeers: []string{"10.11.2.2"}}},
		{"one invalid entry among valid ones", &cloudflarerealip.Config{Header: "CF-Connecting-IP", TrustedPeers: []string{"10.11.2.2/32", "nope"}}},
		{"empty header", &cloudflarerealip.Config{TrustedPeers: []string{"10.11.2.2/32"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			handler, err := cloudflarerealip.New(context.Background(), http.NotFoundHandler(), tc.cfg, "test")
			if err == nil {
				t.Errorf("New returned handler %v and no error", handler)
			}
		})
	}
}

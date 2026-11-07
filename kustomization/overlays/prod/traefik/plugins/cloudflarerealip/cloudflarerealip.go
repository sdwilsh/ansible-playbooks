package cloudflarerealip

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"strings"
)

type Config struct {
	Header       string   `json:"header"`
	TrustedPeers []string `json:"trustedPeers"`
}

func CreateConfig() *Config {
	return &Config{Header: "CF-Connecting-IP"}
}

type action int

const (
	actionLeave action = iota
	actionDrop
	actionSet
)

type outcome struct {
	action action
	client netip.Addr
}

type middleware struct {
	header  string
	next    http.Handler
	trusted []netip.Prefix
}

func New(_ context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	if cfg.Header == "" {
		return nil, fmt.Errorf("%s: header is empty", name)
	}
	if len(cfg.TrustedPeers) == 0 {
		return nil, fmt.Errorf("%s: trustedPeers is empty", name)
	}
	trusted := make([]netip.Prefix, 0, len(cfg.TrustedPeers))
	for _, entry := range cfg.TrustedPeers {
		prefix, err := netip.ParsePrefix(entry)
		if err != nil {
			return nil, fmt.Errorf("%s: trustedPeers entry %q: %w", name, entry, err)
		}
		trusted = append(trusted, prefix)
	}
	return &middleware{header: cfg.Header, next: next, trusted: trusted}, nil
}

func (m *middleware) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	values := req.Header.Values(m.header)
	result := decide(parsePeer(req.RemoteAddr), strings.Join(values, ","), len(values) > 0, m.trusted)
	switch result.action {
	case actionDrop:
		req.Header.Del(m.header)
	case actionSet:
		req.Header.Set("X-Forwarded-For", result.client.String())
		req.Header.Set("X-Real-Ip", result.client.String())
	}
	m.next.ServeHTTP(rw, req)
}

func parsePeer(remoteAddr string) netip.Addr {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return netip.Addr{}
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}
	}
	return peer.Unmap()
}

func decide(peer netip.Addr, raw string, present bool, trusted []netip.Prefix) outcome {
	if !present {
		return outcome{action: actionLeave}
	}
	if !peer.IsValid() || !contains(trusted, peer) {
		return outcome{action: actionDrop}
	}
	client, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil || client.Zone() != "" {
		return outcome{action: actionDrop}
	}
	return outcome{action: actionSet, client: client.Unmap()}
}

func contains(prefixes []netip.Prefix, addr netip.Addr) bool {
	for _, prefix := range prefixes {
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

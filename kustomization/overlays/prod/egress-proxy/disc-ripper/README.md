# disc-ripper

This instance of Iron Proxy serves the sweep `CronJob` in the `disc-ripper` `Namespace`.
`../README.md` tells how an instance works.

## What the instance allows

The allowlist holds the metadata services that the sweep reads.  `egressproxy.yml` gives each
method and path.

- On `api.themoviedb.org`: the film and series lookups under `/3/`.
- On `api4.thetvdb.com`: the login, the series search and the series data under `/v4/`.
- On `api.opensubtitles.com` and `vip-api.opensubtitles.com`: the login, the subtitle search and the
  download request.  The login reply names one of these two hosts for the session.
- On `www.opensubtitles.com`: the subtitle file, under `/download/` only.  The download reply gives
  the link.
- On `thediscdb.com`: the GraphQL queries.
- On `en.wikipedia.org`: the `/w/api.php` queries.

makemkvcon does not use the proxy settings.  It connects directly, so the `NetworkPolicy` drops
its update check, the proxy logs nothing, and no proxy alert fires.

## The client side

The disc-ripper overlay sets `HTTPS_PROXY` to the `Service` of this instance.  Its `NO_PROXY` is
`bifrost.tswn.us,code.tswn.us`, because these hosts are behind Traefik in the cluster.
disc-ripper refuses a CIDR range or a port in `NO_PROXY`, so the list holds only these two names.
`DISC_EXTRA_CA_FILE` names the root CA of this instance, in `/secrets/egress-proxy/ca.crt`.

Deploy a disc-ripper image with proxy support before the client change.  An older image also
sends its calls through the proxy, because ureq reads `HTTPS_PROXY`.  It does not trust the CA, so
each outside call fails in TLS, and the proxy logs no blocked request.

The sweep pod does not start without its CA `Secret`.  The `Job` then stays active, and the
`CronJob` skips each later run.  The `disc-ripper-pod-not-started` alert fires after 30 minutes.

## The proxy does not stop DNS queries

The `disc-ripper` `Namespace` has the `networkpolicy-allow-to-coredns` component.  CoreDNS forwards
a query for a public name, so a compromised client can put data in the names that it looks up.

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

## The proxy does not stop DNS queries

The `disc-ripper` `Namespace` has the `networkpolicy-allow-to-coredns` component.  CoreDNS forwards
a query for a public name, so a compromised client can put data in the names that it looks up.

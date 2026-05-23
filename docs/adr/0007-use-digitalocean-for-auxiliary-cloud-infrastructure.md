# ADR-0007: Use DigitalOcean for auxiliary cloud infrastructure

Status: Accepted

Date: 2026-05-23

## Context

The platform needs auxiliary cloud infrastructure for support services, update artifact distribution, support bundle storage, webhook workers, notification workers, and potentially lightweight internal APIs.

The project benefits from a cloud provider that is operationally simple and suitable for a small engineering team.

## Decision

Use DigitalOcean as the primary auxiliary cloud infrastructure provider.

DigitalOcean will be used for services such as the support broker, update metadata services, signed artifact storage, support bundle storage, containerized workers, and related operational tooling.

## Consequences

### Positive

- Simpler operational model than larger hyperscalers.
- Good fit for App Platform, Spaces, container registry, and small services.
- Works well alongside Supabase rather than replacing it.
- Helps keep support/update services separate from the core POS runtime.

### Negative

- Does not replace Supabase Cloud as the primary database/control plane.
- Adds another vendor to the platform.
- Production use requires IaC, monitoring, access control, and secret management.
- Not every future enterprise feature may be available as a managed service.

## Notes

DigitalOcean should host auxiliary platform services, not active checkout truth or raw payment data.

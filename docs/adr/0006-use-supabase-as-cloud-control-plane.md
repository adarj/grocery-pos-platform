# ADR-0006: Use Supabase as the cloud control plane

Status: Accepted

Date: 2026-05-23

## Context

The platform needs a cloud control plane for organization/store/register data, management apps, reporting, authentication, role-based access, remote command coordination, register health snapshots, sync status, support sessions, and release assignments.

The platform should avoid making cloud availability a hard requirement for local checkout.

## Decision

Use Supabase as the primary cloud control plane.

Supabase will provide managed Postgres, authentication, row-level security, cloud management data, reporting tables, remote command queues, register health snapshots, support session records, and storage where appropriate.

## Consequences

### Positive

- Provides a strong managed Postgres foundation.
- Supports row-level security for multi-tenant management workflows.
- Good fit for Flutter manager web/mobile apps.
- Reduces backend infrastructure burden in early development.
- Works well with local-first POS sync patterns.

### Negative

- Supabase Cloud is an external managed platform dependency.
- Supabase availability must not be required for local checkout.
- RLS policies and migrations must be tested carefully.
- Some backend/service logic may still require custom services outside Supabase.

## Notes

Supabase is the cloud business/control-plane truth. SQLite remains the local register truth for checkout operation.

# Worked mini-example — the depth calibration anchor

The body's Stage A/B/C section lists are the template; this file is the calibration for how
DEEP each level goes, read when calibrating spec depth in step 3 before opening the Workflow.

> The stack, directory layout, tooling and item numbers below are **illustrative fiction**. What
> to copy is the DEPTH and the specificity — naming real files, real commands, real test
> assertions. Substitute your own repo's structure; never carry these paths into a real spec.

Worked example uses DevStride's own org naming (Solution → Capability → Epic → Story); your org's names come from `get_work_type_hierarchy`.

**Capability — "Attachment Handling"** (one paragraph, no build plan):

> Customers and agents can attach files to conversation comments; attachments are scanned, stored in S3, and rendered inline in both the customer portal and the internal item drawer. Design doc §4.1, §4.6.

**Epic — "V1 - Attachment Storage & Scanning"** (under that Capability):

> **Business Description:** Establishes the storage/scan pipeline every attachment-producing surface depends on; nothing downstream (portal upload, email inbound, drawer render) can ship until this lands. Design doc §4.1.
>
> **Architectural Overview:**
> - Storage side: new `attachment` table + S3 bucket policy — owned by I20101.
> - Scan side: virus-scan Lambda trigger on S3 `ObjectCreated`, writes `scan_status` back to `attachment` — owned by I20102.
>
> **Key invariants this epic establishes:** No attachment is ever rendered or linked before `scan_status = 'clean'`.
>
> **Cross-epic contracts:** Comment-side epics reference `attachment.id` via a join table, never a raw S3 key.
>
> **Delivery Sequence:**
> 1. I20101 — attachment table + S3 bucket, no dependencies, start immediately.
> 2. I20102 — scan Lambda, blocked_by I20101 (needs the table to write status into).

**Story — I20101 "Add attachment table + S3 bucket"**

> **Business Description:** Foundation for all attachment features; every other attachment story depends on this schema and bucket existing. Design doc §4.1.
>
> **Architectural Design**
> - *Data Model:* New `attachment` table — `id uuid pk`, `s3_key text not null`, `scan_status attachment_scan_status not null default 'pending'`, `created_by uuid references users(id)`. File: `backend/src/modules/attachment/database/sql/entities/attachment.sql-entity.ts`. Run `pnpm -C backend generate-sql` after editing.
> - *Backend:* New `attachment` module scaffold — repository, domain entity, `CreateAttachment` command. S3 bucket provisioned in `infra/attachments.ts` (Pulumi), private, org-scoped prefix.
> - *Frontend:* None in this story — upload UI is a separate story (I20103).
> - *Permissions and Security:* Gate creation on `ATTACHMENT_UPLOAD`. Bucket policy denies public read; all reads go through a signed-URL endpoint (separate story).
> - *Testing:* `backend/tests/suits/attachment/create-attachment.spec.ts` — row created with default `pending` status; S3 key format matches `org/{orgId}/attachments/{uuid}`; unauthorized user (missing `ATTACHMENT_UPLOAD`) gets 403.
>
> **Dependencies:** Blocks I20102 (scan Lambda needs the table). No blockers of its own — start immediately.
>
> **Edge Cases:** Duplicate upload of identical file content is NOT deduped in v1 (explicit scope decision, not an oversight).
>
> **Definition of Done:** Migration applied, table exists, S3 bucket provisioned, spec file green, `ATTACHMENT_UPLOAD` permission key registered.

**Story — I20102 "Add virus-scan Lambda for attachments"** — `blocked_by: [I20101]`, its own full spec following the same template.

That's the depth bar: container (Capability) = one paragraph; release unit (Epic) = architecture + invariants + sequencing; leaf (Story) = implementation-ready spec a build loop can execute with minimal back-and-forth, including named edge cases and an explicit Definition of Done. The leaf shown is the full template; under `prototype` the same story collapses to the shorter section set its `specDepth` row names, and the two stories would likely be one slice.

## Cited by

- `skills/plan/SKILL.md` — step 3's pointer ("Read … when you calibrate spec depth in step 3,
  before opening the Workflow").

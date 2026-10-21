# TAM email notifications

Deployed to Supabase project `asupemsmwzrovucpvqyt` on 21 October 2026.
Sender: `NonStop Travels <noreply@nonstoptravels.co>`.

## Enabled events

Supabase Auth continues to send event 1 (registration verification) and event 3
(password recovery) through its separately configured custom SMTP connection.
This implementation does not replace Auth SMTP or alter verification templates.

The database generates events 2, 5, 6, 7, 8, 10, 12, 13, 14, 15, 16, 17,
18, 23, 24, 25 and 26. Events that were not selected are not implemented.
Only future committed writes generate notifications; existing records are not replayed.

| Event | Recipients |
|---|---|
| 2 Welcome after verification | Account holder |
| 5 Role changed | Affected account holder |
| 6 Application submitted | Applicant, current admins, assigned staff if present |
| 7 First staff assignment | Applicant and assigned staff |
| 8 Staff reassignment or removal | Applicant, previous staff, new staff if present |
| 10 Agent supervisor assignment | Agent and supervising staff |
| 12 Application stage changed | Applicant and assigned staff |
| 13 Stage advance requested | Current admins |
| 14 Stage advance approved | Requesting staff and currently assigned staff |
| 15 Stage request held | Requesting staff and currently assigned staff |
| 16 Application approved | Applicant and assigned staff |
| 17 Application rejected | Applicant and assigned staff |
| 18 Document uploaded | Applicant uploads: assigned staff. Other uploads: applicant and assigned staff; exclude uploader |
| 23 Deletion requested | Current admins |
| 24 Deletion approved or rejected | Requesting staff and currently assigned staff |
| 25 Application deleted | Applicant and assigned staff, captured before deletion |
| 26 Account deleted | Account holder, captured before profile deletion |

Applicant addresses come from `applications.email`, not the account that created
the application (which can be an agent). Staff are resolved by foreign keys, not
name matching. Missing staff assignments are skipped; recipient addresses are
normalized and deduplicated per event. A final approval generates event 16 rather
than another event 12. Internal request decisions do not include applicants.

The existing stage-request schema supports `pending`, `approved` and `pended`;
`pended` is described as put on hold. It does not support a separate rejected
stage-request state. The trigger also handles `rejected` if added in a later migration.

## Architecture and security

Changes enqueue plain-text messages in `tam_private.email_outbox` transactionally.
There are no HTTP calls in data-change triggers. A cron job checks once per minute
and calls `tam-email-worker` only when messages are due. SMTP outages do not stop
application writes. Failed messages retry with backoff, up to five attempts.
Processing leases expire after five minutes so interrupted jobs can recover.

SMTP delivery is at least once: a crash after SMTP acceptance but before saving
the result can cause a retry. Stable Message-IDs help identify duplicates but are
not a guarantee that a provider will suppress them.

The Edge Function uses custom authentication: a random worker token is generated
inside Supabase Vault and is never committed to GitHub. The function checks it via
a service-role-only RPC before accessing credentials or processing messages.
`verify_jwt=false` is intentional because cron uses this custom token. Requests
without a valid token cannot send email or read queued messages.

The private schema is not exposed to client roles. Queue/settings tables have RLS
and explicit deny policies. Supporting trigger functions have client execution
revoked and fixed search paths. No SMTP credentials are stored in frontend code.
Email bodies escape dynamic content and do not include document attachments,
document URLs, private notes, passwords or security-question answers.

`profiles.assigned_staff_id` was added because the existing agent-management UI
already writes this field, but it was absent from the database. No assignments
were inferred or backfilled.

The existing `admin_delete_application` RPC now records a pending deletion request
as approved before removing it, allowing its staff notification to be captured.
The existing `update_user_role` RPC now checks that the caller is an admin and
accepts only known roles. Anonymous execution of these two RPCs is revoked.

## Secrets and deployment

Required Edge Function secrets: `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`,
`SMTP_PASSWORD`. Use TLS port 465; Supabase Edge Functions block ports 25 and 587.
These are separate from the SMTP settings under Supabase Authentication.
The runtime supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.

The deployment is already applied. Do not rerun the setup script against the
existing database. For a fresh compatible database, apply the infrastructure,
events and security sections in `tam-email-setup.sql`, deploy the worker, run
the SQL tests, verify SMTP, then apply `tam-email-activate.sql`.

Deploy the function with JWT verification disabled and the custom token check
intact. Source: `supabase/functions/tam-email-worker/index.ts`.

## Verification performed

- SMTP TLS connection and credential authentication passed from the deployed function.
- Selected event recipient-routing tests passed inside a rolled-back transaction.
- Real deletion-RPC flow tested with temporary fixtures and rolled back.
- Approval suppression, uploader exclusion and recipient deduplication passed.
- Worker invalid-token rejection, disabled state, exclusive leasing, successful
  completion, retry backoff, stale-lease recovery and retry-limit checks passed.
- Non-admin role changes are rejected, and anonymous RPC execution is revoked.
- Enabled cron schedule verified and deployed worker returned HTTP 200.
- No test emails were sent; SMTP sender authorization and inbox delivery are not
  proven until a message is accepted and delivered for a real event.
- All test users and records were rolled back; queue was empty at activation.

## Operations (Supabase SQL Editor)

```sql
-- Delivery status, without printing email addresses or bodies:
select event_no,status,count(*) from tam_private.email_outbox group by 1,2;
select id,event_no,status,attempts,last_error,created_at,sent_at
from tam_private.email_outbox where status='failed' order by created_at desc;

-- Pause/resume sending (events continue to queue):
update tam_private.email_settings set enabled=false where id;
update tam_private.email_settings set enabled=true where id;

-- SMTP verification (returns request ID; does not send email):
select tam_private.invoke_email_worker('verify');
-- Inspect the matching request ID in net._http_response for its sanitized result.

-- Retry failed messages after fixing the SMTP issue:
update tam_private.email_outbox set status='pending',attempts=0,
 available_at=now(),last_error=null,lease=null,leased_at=null
where status='failed';
```

Auth settings cannot be inspected or changed through the connected Supabase MCP
tools. Registration/recovery end-to-end delivery was not tested by generating
verification or password-reset emails for real users.

## Branded email design

All 17 custom notification types use the shared `email-template.ts` layout: the original NonStop Travels logo, website green (#075b32 / #064125) and orange (#f58220), white content area, mobile styling, structured application details, trusted portal/support buttons, and the verified website contact details. The logo is a 480px PNG rendered from the website's original SVG and embedded as an inline CID attachment from `email-logo.ts`. No external image fetch is required. Deploy index.ts together with both relative modules.

Plain-text mail includes the portal or support link. Deleted-account/application messages point to support. Dynamic content is HTML-escaped. Template checks cover all 17 events, escaping, logo CID, action URLs and size. Welcome and progress previews were rendered and inspected at 660px and 375px widths using WeasyPrint; native email-client rendering was not tested. SMTP authentication passed after deployment. No additional preview email was sent.

Run `node --experimental-strip-types email-template.test.mjs` from the function directory for template checks and HTML previews. Optional `--browser` checks require a separately installed Playwright browser.

Supabase Auth verification and recovery emails still use their separately managed Auth templates; this design change applies to the custom TAM notification worker only.

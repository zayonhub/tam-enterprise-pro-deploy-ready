import nodemailer from "npm:nodemailer@10.1.7";
import { renderEmail, LOGO_CID, PORTAL_URL, SUPPORT_EMAIL } from "./email-template.ts";
import { LOGO_BASE64 } from "./email-logo.ts";

const FROM = "noreply@nonstoptravels.co";
const reply = (data: unknown, status = 200) => Response.json(data, { status });
const safeCode = (e: any) => typeof e?.code === "string" && /^[A-Z_0-9]+$/.test(e.code) ? e.code : "SMTP_FAILED";
const safeFailure = (e: any) => {
  let message = String(e?.message || "SMTP failure");
  for (const name of ["SMTP_PASSWORD", "SMTP_USER", "SUPABASE_SERVICE_ROLE_KEY"]) {
    const value = Deno.env.get(name);
    if (value) message = message.split(value).join("[redacted]");
  }
  return (safeCode(e) + ": " + message.replace(/[\r\n]/g, " ")).slice(0,100);
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return reply({ error: "method_not_allowed" }, 405);
  const token = req.headers.get("x-worker-token");
  if (!token || token.length > 200) return reply({ error: "unauthorized" }, 401);
  const base = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!base || !serviceKey) return reply({ error: "server_configuration" }, 503);
  const rpc = async (p_op: string, args: Record<string, unknown> = {}) => {
    const res = await fetch(base + "/rest/v1/rpc/tam_email_worker", {
      method: "POST",
      headers: { "Content-Type": "application/json", apikey: serviceKey, Authorization: "Bearer " + serviceKey },
      body: JSON.stringify({ p_token: token, p_op, ...args }),
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) throw new Error("worker_rpc_" + res.status);
    return await res.json();
  };
  try { await rpc("check"); } catch { return reply({ error: "unauthorized" }, 401); }
  let mode = "run";
  try { mode = (await req.json()).mode || "run"; } catch { return reply({ error: "invalid_json" }, 400); }
  if (!["run", "verify"].includes(mode)) return reply({ error: "invalid_mode" }, 400);
  const names = ["SMTP_HOST", "SMTP_PORT", "SMTP_USER", "SMTP_PASSWORD"];
  const missing = names.filter(n => !Deno.env.get(n));
  if (missing.length) return reply({ error: "missing_secrets", missing }, 503);
  const port = Number(Deno.env.get("SMTP_PORT"));
  if (port !== 465) return reply({ error: "use_tls_port_465", configured_port: port }, 503);
  const transport = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST"), port, secure: true,
    auth: { user: Deno.env.get("SMTP_USER"), pass: Deno.env.get("SMTP_PASSWORD") },
    connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 15000,
    tls: { minVersion: "TLSv1.2", rejectUnauthorized: true },
    logger: false, debug: false, disableFileAccess: true, disableUrlAccess: true,
  });
  if (mode === "verify") {
    try {
      await transport.verify();
      return reply({ smtp_authenticated: true, sender: FROM,
        smtp_host: Deno.env.get("SMTP_HOST"),
        sender_matches_username: Deno.env.get("SMTP_USER")?.toLowerCase() === FROM,
        username_is_email: /^[^@\s]+@[^@\s]+$/.test(Deno.env.get("SMTP_USER") || "") });
    } catch (e) { return reply({ smtp_authenticated: false, error: safeCode(e) }, 502); }
    finally { transport.close(); }
  }
  let sent = 0, failed = 0;
  try {
    const jobs = await rpc("claim");
    for (const job of jobs) {
      let success = false, error = "";
      try {
        const info = await transport.sendMail({
          from: { name: "NonStop Travels", address: FROM },
          to: { address: job.recipient, name: "" },
          subject: "NonStop Travels | " + job.subject.replace(/[\r\n]/g, " "),
          text: job.body + "\n\n" + ([25,26].includes(job.event_no) ? "Contact our team: " + SUPPORT_EMAIL : "Open your portal: " + PORTAL_URL) + "\n\nNonStop Travels Limited\nSupport: " + SUPPORT_EMAIL + "\nThis is an automated notification. Please do not reply to this address.",
          html: renderEmail(job),
          attachments: [{ filename: "nonstop-travels-logo.png", content: LOGO_BASE64, encoding: "base64", cid: LOGO_CID, contentType: "image/png", contentDisposition: "inline" }],
          messageId: "<tam-" + job.id + "@nonstoptravels.co>",
        });
        success = Array.isArray(info.accepted) && info.accepted.length > 0;
        if (!success) error = "RECIPIENT_REJECTED";
      } catch (e) { error = safeFailure(e); }
      const result = await rpc("complete", { p_id: job.id, p_lease: job.lease, p_success: success, p_error: error });
      if (!result.updated) throw new Error("lease_lost");
      success ? sent++ : failed++;
    }
    return reply({ sent, failed });
  } catch { return reply({ error: "processing_failed", sent, failed }, 500); }
  finally { transport.close(); }
});

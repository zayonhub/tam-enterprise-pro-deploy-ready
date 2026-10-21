export const LOGO_CID = "nonstop-travels-logo@nonstoptravels.co";
export const PORTAL_URL = "https://application.nonstoptravels.co/";
export const SUPPORT_EMAIL = "info@nonstoptravels.co";
export function escapeHtml(value: string): string {
  return String(value).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));
}

export function renderEmail(job: {event_no: number; subject: string; body: string}, logoSrc = "cid:" + LOGO_CID): string {
  const detailRows: [string,string][] = [];
  const paragraphs: string[] = [];
  const lines: string[] = [];
  for (const line of String(job.body).split(/\r?\n/)) {
    const match = line.match(/^(Applicant|Application reference|Current stage|Current staff|Agent|Supervising staff):\s*(.*)$/);
    if (match) detailRows.push([match[1], match[2]]);
    else lines.push(line);
  }
  for (const p of lines.join("\n").split(/\n\s*\n/)) {
    if (p.trim()) paragraphs.push(`<p style="margin:0 0 18px;color:#52665b;font-size:16px;line-height:1.75;">${escapeHtml(p.trim()).replace(/\n/g,"<br>")}</p>`);
  }
  const welcome = job.event_no === 2;
  const deleted = [25,26].includes(job.event_no);
  const action = [13,23].includes(job.event_no);
  const category = welcome ? "WELCOME ABOARD" : action ? "ACTION REQUESTED" : [5,26].includes(job.event_no) ? "ACCOUNT NOTIFICATION" : "APPLICATION NOTIFICATION";
  const heading = welcome ? "Your journey starts here." : job.subject;
  const preview = escapeHtml(welcome ? "Welcome to NonStop Travels. Your next step starts with us." : job.subject + ". Sign in to your NonStop Travels portal for details.");
  const buttonUrl = deleted ? "mailto:" + SUPPORT_EMAIL : PORTAL_URL;
  const buttonText = deleted ? "Contact our team" : action ? "Review in your portal" : welcome ? "Open your portal" : "View in your portal";
  const details = detailRows.length ? `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="border-collapse:collapse;margin:4px 0 26px;border-top:1px solid #dfeae3;">${detailRows.map(([label,value])=>`<tr><td valign="top" width="40%" style="padding:13px 12px 13px 0;border-bottom:1px solid #dfeae3;font-size:13px;line-height:1.6;color:#61756a;">${escapeHtml(label)}</td><td valign="top" style="padding:13px 0;border-bottom:1px solid #dfeae3;font-size:14px;line-height:1.6;font-weight:bold;color:#17352a;word-break:break-word;">${escapeHtml(value)}</td></tr>`).join("")}</table>` : "";
  return `<!doctype html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta name="color-scheme" content="light"><title>${escapeHtml(job.subject)}</title>
<style>body,table,td,a{-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%}table,td{mso-table-lspace:0pt;mso-table-rspace:0pt}img{border:0;outline:none;text-decoration:none;-ms-interpolation-mode:bicubic}table{border-collapse:collapse}table[width="100%"]{width:100%}a{color:#075b32}@media only screen and (max-width:620px){.outer-pad{padding:18px 10px!important}.content-pad{padding-left:24px!important;padding-right:24px!important}.email-heading{font-size:29px!important}.email-logo{width:215px!important;height:auto!important}.header-caption{display:none!important}.cta{display:block!important;text-align:center!important}}</style></head>
<body style="margin:0;padding:0;background-color:#f3f6f4;font-family:Arial,Helvetica,sans-serif;color:#17352a;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">${preview}</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#f3f6f4"><tr><td class="outer-pad" align="center" style="padding:36px 16px;">
<!--[if mso]><table role="presentation" width="600" align="center" cellpadding="0" cellspacing="0"><tr><td><![endif]-->
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" bgcolor="#ffffff" style="max-width:600px;background-color:#ffffff;">
<tr><td class="content-pad" style="padding:30px 38px 28px;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr><td><a href="https://nonstoptravels.co/" style="text-decoration:none;"><img class="email-logo" src="${escapeHtml(logoSrc)}" alt="NonStop Travels" width="240" height="54" style="display:block;width:240px;height:auto;max-width:100%;"></a></td><td class="header-caption" align="right" style="text-align:right;font-size:11px;line-height:1.6;color:#61756a;">Travel with clarity.<br>Move with confidence.</td></tr></table>
</td></tr>
<tr><td height="4" bgcolor="#f58220" style="height:4px;background-color:#f58220;font-size:0;line-height:0;">&nbsp;</td></tr>
<tr><td class="content-pad" style="padding:35px 38px 8px;">
<p style="margin:0 0 15px;font-size:11px;line-height:1.5;letter-spacing:2px;font-weight:bold;color:#07883f;">${category}</p>
<h1 class="email-heading" style="margin:0 0 24px;font-family:Arial,Helvetica,sans-serif;font-size:34px;line-height:1.16;letter-spacing:-1px;color:#075b32;font-weight:bold;">${escapeHtml(heading)}</h1>
${paragraphs.join("")}${details}
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:9px 0 27px;"><tr><td bgcolor="#f58220" style="background-color:#f58220;border-radius:8px;mso-padding-alt:16px 24px;"><a class="cta" href="${buttonUrl}" style="display:inline-block;padding:16px 24px;background-color:#f58220;border:1px solid #f58220;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.3;font-weight:bold;color:#ffffff;text-decoration:none;">${buttonText}</a></td></tr></table>
</td></tr>
<tr><td class="content-pad" style="padding:0 38px 30px;"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr><td style="border-top:1px solid #dfeae3;padding-top:22px;"><p style="margin:0 0 7px;font-size:14px;line-height:1.6;font-weight:bold;color:#17352a;">Need a hand with your next step?</p><p style="margin:0;font-size:13px;line-height:1.7;color:#61756a;">Email <a href="mailto:${SUPPORT_EMAIL}" style="color:#075b32;text-decoration:underline;">${SUPPORT_EMAIL}</a> or call<br><a href="tel:+2347086290768" style="color:#075b32;text-decoration:none;">+234 708 629 0768</a>.</p></td></tr></table></td></tr>
<tr><td class="content-pad" bgcolor="#064125" style="padding:24px 38px;background-color:#064125;color:#ffffff;"><p style="margin:0 0 6px;font-size:14px;line-height:1.5;font-weight:bold;color:#ffffff;">NonStop Travels Limited</p><p style="margin:0;font-size:12px;line-height:1.7;color:#d9eadd;">Part of NonStop Groups<br>Sefe Plaza, Akala Expressway, New Garage, Ibadan, Nigeria</p></td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:600px;"><tr><td align="center" style="padding:20px 20px 0;"><p style="margin:0;font-size:11px;line-height:1.7;color:#61756a;">This is an automated account or application notification.<br>Please do not reply to this address. For help, contact our team above.<br>&copy; ${new Date().getUTCFullYear()} NonStop Travels Limited.</p></td></tr></table>
</td></tr></table></body></html>`;
}

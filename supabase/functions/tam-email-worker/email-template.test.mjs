import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { renderEmail, LOGO_CID, PORTAL_URL } from './email-template.ts';
import { LOGO_BASE64 } from './email-logo.ts';

for (const event_no of [2,5,6,7,8,10,12,13,14,15,16,17,18,23,24,25,26]) {
 const html = renderEmail({event_no,subject:'Application progress update',body:'Your application has progressed.\n\nApplicant: Test Applicant\nApplication reference: ABC12345\nCurrent stage: Document Preparation'});
 assert.ok(html.includes('cid:'+LOGO_CID));
 assert.ok(html.includes('Applicant'));
 assert.ok(html.includes('ABC12345'));
 assert.ok(!html.includes('nonstopgroup.co'));
 assert.ok(html.includes([25,26].includes(event_no)?'mailto:info@nonstoptravels.co':PORTAL_URL));
 assert.ok(Buffer.byteLength(html)<15000);
}
const hostile = renderEmail({event_no:12,subject:'<script>alert(1)</script>',body:'Applicant: <img src=x onerror=alert(1)>\nCurrent stage: <script>1</script>'});
assert.ok(!hostile.includes('<script>'));
assert.ok(!hostile.includes('<img src=x'));
assert.ok(hostile.includes('&lt;script&gt;'));
assert.ok(Buffer.from(LOGO_BASE64,'base64').length>1000);
console.log('PASS: all 17 templates, trusted action links, escaping, CID logo and message size');

const welcome={event_no:2,subject:'Welcome to NonStop Travels',body:'Your email has been verified. Welcome to NonStop Travels.\n\nYou can sign in to your portal to submit an application, upload documents and follow your application progress.'};
const update={event_no:12,subject:'Application progress update',body:'Your application has moved to the next stage.\n\nApplicant: Sample Applicant\nApplication reference: NST48216\nCurrent stage: Document Preparation'};
for(const [name,job] of [['welcome',welcome],['update',update]]){
 const html=renderEmail(job,'data:image/png;base64,'+LOGO_BASE64);
 fs.writeFileSync('preview-'+name+'.html',html);
}
if(process.argv.includes('--browser')){
const require = createRequire(import.meta.url);
const {chromium} = require('playwright');
const browser=await chromium.launch({headless:true});
const page=await browser.newPage();
for(const [name] of [['welcome'],['update']]){
 const html=fs.readFileSync('preview-'+name+'.html','utf8');
 for(const width of [736,375]){
  await page.setViewportSize({width,height:1000});
  await page.setContent(html,{waitUntil:'load'});
  await page.screenshot({path:'preview-'+name+'-'+width+'.png',fullPage:true});
  const state=await page.evaluate(()=>({overflow:document.documentElement.scrollWidth>innerWidth,logo:document.querySelector('img').naturalWidth}));
  assert.equal(state.overflow,false,'Horizontal overflow at '+width);
  assert.equal(state.logo,480,'Logo failed to render');
 }
}
await browser.close();
console.log('PASS: welcome and progress layouts at desktop and mobile widths, with embedded logo');
}

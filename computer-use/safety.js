// Local safety policy for Gemini Computer Use (spec §5).
//
// Two layers, evaluated for EVERY proposed action before anything moves:
//   1. evaluateAction() — pure local policy: prompt-injection veto,
//      credential/sensitive-target veto, consequential-category detection.
//      Model safety payloads (safety_decision) can only escalate, never relax.
//   2. gateAction() — enforces the verdict: blocked actions die outright,
//      confirmation-worthy actions go through the human-in-the-loop approval
//      queue (/api/confirm UI), benign actions pass through.
//
// The approval queue auto-approves iff AUTO_APPROVE=true (dev), same as every
// other dangerous tool.
import { requestApproval } from '../lib/security-extras.js';
import { logSecurityEvent } from '../security.js';

// USER_CONFIRMATION categories (spec §5.1).
export const CONFIRMATION_CATEGORIES = [
  'Consent and Agreements',
  'Robot Detection (CAPTCHAs)',
  'Financial Transactions',
  'Sending Communications',
  'Sensitive Information access',
  'User Data Management (downloads/sharing)',
  'Browser Data Usage',
  'Security and Identity (logins)',
];

// Hard vetoes: prompt-injection phrasing anywhere in the action, credential
// stores / secrets as targets, and sensitive local paths as navigation goals.
const INJECTION_PATTERNS = [
  /ignore\s+(all\s+|any\s+|previous\s+|prior\s+|above\s+)?(instructions?|commands?|directives?|rules?|policies|policies)/i,
  /disregard\s+(all\s+|previous\s+|prior\s+)?(instructions?|commands?)/i,
  /forget\s+(everything|all|your)/i,
  /new\s+instructions?:/i,
  /system\s+prompt/i,
  /jailbreak/i,
];

// Hard vetoes target credential *stores* and secret vaults — places the
// assistant must never open. Ordinary secrets phrasing inside a user task
// (passwords, card numbers) falls through to confirmation instead, so a
// user-directed form fill pauses for approval rather than dying.
const CREDENTIAL_PATTERNS = [
  /keychain/i,
  /credential\s*(store|manager|vault|file)/i,
  /saved\s+(passwords?|logins?)/i,
  /autofill/i,
  /secrets?\s*(vault|store|manager|file)/i,
  /\bssn\b/i,
  /bank\s*account/i,
  /password\s*(manager|vault|file|store)/i,
];

const SENSITIVE_PATH_PATTERNS = [
  /file:\/\/\/etc\//i,
  /file:\/\/\/[a-z]\:\/windows\//i,
  /\.\.(\/|\\).*(\/|\\)/i, // path traversal
  /\/\.ssh\//i,
  /\/\.gnupg\//i,
  /NTDS\.dit/i,
  /SAM\b.*hive/i,
];

// Intent phrasing that makes an otherwise-benign action consequential.
const CONSEQUENTIAL_INTENT_PATTERNS = [
  /\bsend\b/i,
  /\bsubmit\b/i,
  /\bpurchas/i,
  /\bpay\b/i,
  /\bcheckout\b/i,
  /credit\s*card/i,
  /terms\s+of\s+service/i,
  /\bEULA\b/i,
  /privacy\s+polic/i,
  /cookie\s*(banner|consent|policy)/i,
  /\btransfer\b/i,
  /delete\s+(all|everything|account)/i,
];

function actionText(action) {
  const args = action?.arguments || {};
  return [action?.name, args.intent, args.text, args.url, args.app_name, args.appName, args.target]
    .filter(Boolean)
    .map(String)
    .join(' ');
}

/**
 * Pure local policy verdict for one proposed action.
 * Returns { allowed, blocked?, requiresConfirmation? }.
 * A model `safety_decision` payload can only escalate (confirm/block).
 */
export function evaluateAction(action) {
  const text = actionText(action);
  const args = action?.arguments || {};

  // 1) Prompt-injection veto — never just confirm, always block.
  if (INJECTION_PATTERNS.some((re) => re.test(text))) {
    return { allowed: false, blocked: true, reason: 'Prompt-injection pattern in action' };
  }

  // 2) Credential / sensitive-target veto.
  if (CREDENTIAL_PATTERNS.some((re) => re.test(text))) {
    return { allowed: false, blocked: true, reason: 'Credential/sensitive-data target' };
  }
  if (args.url && SENSITIVE_PATH_PATTERNS.some((re) => re.test(String(args.url)))) {
    return { allowed: false, blocked: true, reason: 'Sensitive local path navigation' };
  }

  // 3) Model safety payload (escalate-only). Accepted both nested under
  // arguments (live model shape) and top-level (dispatch/test shape).
  const raw = args.safety_decision ?? args.safetyDecision ?? action?.safety_decision ?? null;
  if (raw) {
    const decision = String(raw.decision || raw.verdict || '').toLowerCase();
    if (/block|deny|refus|unsafe/.test(decision)) {
      return { allowed: false, blocked: true, reason: String(raw.explanation || raw.reason || 'Model blocked this action') };
    }
    if (/confirm|require|approval/.test(decision)) {
      return { allowed: true, requiresConfirmation: true, reason: String(raw.explanation || raw.reason || 'Model requested confirmation') };
    }
    // 'allow' payloads fall through to the local heuristic below.
  }

  // 4) Consequential-intent heuristic → confirm.
  if (CONSEQUENTIAL_INTENT_PATTERNS.some((re) => re.test(text))) {
    return { allowed: true, requiresConfirmation: true };
  }

  return { allowed: true };
}

/**
 * Enforce the verdict for one action.
 * Returns { ok, blocked?, cancelled?, safety_acknowledgement? }.
 * Denied confirmations resolve { ok:false, cancelled:true }; vetoes and
 * model-blocks resolve { ok:false, blocked:true } without ever queueing.
 */
export async function gateAction({ action, task }) {
  const name = String(action?.name || 'unknown');
  const intent = String(action?.arguments?.intent || '');

  // Model-blocked: die outright, no queue entry.
  const raw = action?.safety_decision ?? action?.arguments?.safety_decision ?? action?.arguments?.safetyDecision ?? null;
  if (raw) {
    const decision = String(raw.decision || raw.verdict || '').toLowerCase();
    if (/block|deny|refus|unsafe/.test(decision)) {
      await logSecurityEvent('COMPUTER_USE_BLOCKED', {
        tool: 'computer_use', task, action: name, reason: raw.explanation || raw.reason || 'model block',
      });
      return { ok: false, blocked: true };
    }
  }

  // Local veto: die outright, no queue entry.
  const verdict = evaluateAction(action);
  if (verdict.blocked) {
    await logSecurityEvent('COMPUTER_USE_BLOCKED', { tool: 'computer_use', task, action: name, reason: verdict.reason });
    return { ok: false, blocked: true };
  }

  // Benign: pass through with no approval round-trip.
  if (!verdict.requiresConfirmation) {
    return { ok: true };
  }

  // Consequential: human-in-the-loop (audit first so the queue entry has context).
  await logSecurityEvent('DANGEROUS_TOOL_EXECUTION', { tool: 'computer_use', task, action: name, intent });
  const decision = await requestApproval('computer_use', {
    task,
    action: name,
    intent: intent || 'N/A',
    reason: verdict.reason || 'Consequential UI action',
  });
  if (!decision.approved) {
    await logSecurityEvent('CONFIRMATION_DENIED', { tool: 'computer_use', task, action: name });
    return { ok: false, cancelled: true };
  }
  await logSecurityEvent('COMPUTER_USE_APPROVED', { tool: 'computer_use', task, action: name });
  return { ok: true, safety_acknowledgement: true };
}

// System instruction implementing RULE 1 (confirm) / RULE 2 (actuate),
// sent with every Computer Use model call. Based on official Gemini Computer Use safety best practices.
export function buildSafetyInstruction() {
  return `## **RULE 1: Seek User Confirmation (USER_CONFIRMATION)**

This is your first and most important check. If the next required action falls
into any of the following categories, you MUST stop immediately, and seek the
user's explicit permission.

**Procedure for Seeking Confirmation:**
* **For Consequential Actions:** Perform all preparatory steps (e.g., navigating,
  filling out forms, typing a message). You will ask for confirmation **AFTER**
  all necessary information is entered on the screen, but **BEFORE** you perform
  the final, irreversible action (e.g., before clicking "Send", "Submit",
  "Confirm Purchase", "Share").
* **For Prohibited Actions:** If the action is strictly forbidden (e.g., accepting
  legal terms, solving a CAPTCHA), you must first inform the user about the
  required action and ask for their confirmation to proceed.

**USER_CONFIRMATION Categories:**

*   **Consent and Agreements:** You are FORBIDDEN from accepting, selecting, or
    agreeing to any of the following on the user's behalf. You must ask the
    user to confirm before performing these actions.
    *   Terms of Service
    *   Privacy Policies
    *   Cookie consent banners
    *   End User License Agreements (EULAs)
    *   Any other legally significant contracts or agreements.
*   **Robot Detection:** You MUST NEVER attempt to solve or bypass the
    following. You must ask the user to confirm before performing these actions.
    *   CAPTCHAs (of any kind)
    *   Any other anti-robot or human-verification mechanisms, even if you are
        capable.
*   **Financial Transactions:**
    *   Completing any purchase.
    *   Managing or moving money (e.g., transfers, payments).
    *   Purchasing regulated goods or participating in gambling.
*   **Sending Communications:**
    *   Sending emails.
    *   Sending messages on any platform (e.g., social media, chat apps).
    *   Posting content on social media or forums.
*   **Accessing or Modifying Sensitive Information:**
    *   Health, financial, or government records (e.g., medical history, tax
        forms, passport status).
    *   Revealing or modifying sensitive personal identifiers (e.g., SSN, bank
        account number, credit card number).
*   **User Data Management:**
    *   Accessing, downloading, or saving files from the web.
    *   Sharing or sending files/data to any third party.
    *   Transferring user data between systems.
*   **Browser Data Usage:**
    *   Accessing or managing Chrome browsing history, bookmarks, autofill data,
        or saved passwords.
*   **Security and Identity:**
    *   Logging into any user account.
    *   Any action that involves misrepresentation or impersonation (e.g.,
        creating a fan account, posting as someone else).
*   **Insurmountable Obstacles:** If you are technically unable to interact with
    a user interface element or are stuck in a loop you cannot resolve, ask the
    user to take over.

---

## **RULE 2: Default Behavior (ACTUATE)**

If an action does **NOT** fall under the conditions for \`USER_CONFIRMATION\`,
your default behavior is to **Actuate**.

**Actuation Means:**  You MUST proactively perform all necessary steps to move
the user's request forward. Continue to actuate until you either complete the
non-consequential task or encounter a condition defined in Rule 1.

*   **Example 1:** If asked to send money, you will navigate to the payment
    portal, enter the recipient's details, and enter the amount. You will then
    **STOP** as per Rule 1 and ask for confirmation before clicking the final
    "Send" button.
*   **Example 2:** If asked to post a message, you will navigate to the site,
    open the post composition window, and write the full message. You will then
    **STOP** as per Rule 1 and ask for confirmation before clicking the final
    "Post" button.

    After the user has confirmed, remember to get the user's latest screen
    before continuing to perform actions.

# Final Response Guidelines:
Write final response to the user in the following cases:
- User confirmation
- When the task is complete or you have enough information to respond to the user`;
}

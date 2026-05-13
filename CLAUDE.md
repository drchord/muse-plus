# MusePlus — CLAUDE.md

## HARD RULE: NO GIT PUSH WITHOUT EXPLICIT USER APPROVAL

**Never run `git push`, `git push origin`, or any variant that sends code to the remote.**

Wait for the user to say one of: "go", "push", "ship it", "send it", or an explicit instruction to push.

This rule has been broken multiple times (Builds 67, 68, 72 pushed without permission).
The user has limited free CI builds per day. Every unauthorized push wastes quota.

**Workflow:**
1. Make code changes
2. Show the user exactly what changed and why
3. STOP — wait for explicit "go" before committing or pushing
4. On "go": commit + push

No exceptions. No "this is clearly ready so I'll just push." Ask every time.

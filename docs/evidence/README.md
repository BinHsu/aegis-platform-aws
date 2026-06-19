# DR drill evidence

This directory holds the timed CLI evidence a disaster-recovery drill produces.

**No drill artifacts are committed yet.** Earlier measured-DR records were removed
when this repo was extracted from its single-repo origin, because they could not be
honestly rebranded to the current topology. Rather than ship fabricated numbers, the
DR target was downgraded to a `~20–30 min` cold-rebuild estimate (see
[ADR-05](../adr/05-disaster-recovery.md)) until a fresh drill produces real ones.

## How to reproduce the evidence

Run the drill against a region; the helper sequences the phases, times each, and
writes a timestamped report here:

```bash
scripts/dr/dr-drill.sh eu-central-1
```

The full procedure — failure-mode matrix, RTO/RPO targets, and the manual
step-through — is in [`docs/dr-plan.md`](../dr-plan.md). A drill costs ~$1–2
(~6 h: stand up → drill → destroy); see [`docs/finops.md`](../finops.md).

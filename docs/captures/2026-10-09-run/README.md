# Run `<DEMO_RUN_ID>` — 2026-10-09

Curated evidence behind [DEMO.md §6](../../DEMO.md#6-the-interruption), preserving
measured timestamps and event ordering without training noise or resource IDs.

This historical capture predates the atomic local checkpoint publication used
today. Its optional `first_step` and `ckpt_saved` events measure timing only.

| File | Evidence retained |
|---|---|
| `attempt1-archived.log` | fresh start, last locally saved step, SIGTERM, and the archived log ending before `drain_done` |
| `attempt2.log` | restore, resume from step 150, continued training, and completion at step 400 |
| `wf.json` | the failed and successful train attempts with the pod timestamps needed for image-pull timing |
| `karpenter.log` | original node lifecycle, interruption handling, taint, and replacement readiness |
| `checkpoints.txt` | S3 metadata-marker progression across the interruption |
| `timeline-attempt*.txt` | exact offline output of `timeline.sh` for each attempt |

Reproduce both committed tables from the repository root:

```bash
for log in attempt1-archived attempt2; do
  n="${log#attempt}"; n="${n%%-*}"
  out="/tmp/timeline-attempt${n}.txt"
  STAGE=train scripts/timeline.sh -w docs/captures/2026-10-09-run/wf.json \
    "docs/captures/2026-10-09-run/${log}.log" >"$out"
  diff -u "docs/captures/2026-10-09-run/timeline-attempt${n}.txt" \
    "$out"
done
```

The tables intentionally omit node-boot and GPU-power rows because the original
Prometheus responses were not retained. Nothing in this directory depends on a
live cluster, AWS credentials, or network access.

Log and Workflow timestamps are UTC. `checkpoints.txt` came from `aws s3 ls` on
a UTC+02 workstation, so its displayed times are two hours ahead. Stable
placeholders preserve relationships; region, availability zone, repository,
image tag, NodePool, W&B project, account, bucket, queue, UUID, host, and run
identifiers are omitted or replaced.

# vanilla-eks-spot-training ⚡

### Pull the GPU. Keep the progress.

> [!NOTE]
> This project was built with the help of AI tools. The code, Terraform, and
> documentation were AI-assisted and reviewed by a human, but may still contain
> mistakes. Review everything before running it in your own AWS account.

`vanilla-eks-spot-training` trains an LLM on Amazon EKS, survives the loss of
its GPU node, and resumes from the latest durable checkpoint on a fresh one.

The demo is deliberately dramatic: start a multi-GPU training run, inject a
Spot interruption event, and watch Karpenter replace the node while the
application restores its state and carries on training.

```text
  TRAINING ──▶ CHECKPOINT ──▶ 💾 S3
      │
      └── ⚡ NODE INTERRUPTED
                    │
                    ▼
              Karpenter replaces it
                    │
                    ▼
          RESTORE ──▶ RESUME ──▶ TRAINING
```

In the recorded run, an interruption at step 107 became a safe checkpoint at
step 125, followed by resumed training on a replacement node about 4½ minutes
after injection. No restart from zero. No lost afternoon.

## Why this matters

GPU training is expensive; interrupted GPU training is expensive *and*
frustrating.

Spot capacity can be heavily discounted compared with On-Demand capacity, but
only if losing an instance does not mean losing the run. Checkpointing changes
the cost of an interruption from hours of repeated work to a few minutes of
recovery. That makes volatile capacity genuinely useful for long-running
training jobs.

See the [EC2 Spot pricing page](https://aws.amazon.com/ec2/spot/pricing/) for
current rates.

## The interesting bit

Karpenter handles the infrastructure half: it receives the interruption event,
cordons and drains the doomed node, and begins provisioning a replacement.

`vanilla-eks-spot-training` handles the application half:

- checkpoints are written atomically;
- incomplete checkpoints are never exposed as resumable;
- committed state is synced to durable S3 storage;
- the replacement restores only the newest complete checkpoint; and
- a constant world size preserves the distributed training shape.

Together, those pieces turn a relaunched pod into a **resumed training run**.
An orchestrator can restart a workload; only the workload can know how to
continue it safely.

The demo uses pinned capacity for repeatable timings and injects the
interruption instead of waiting for the market to provide one. A real Spot
warning and the injected event travel through the same SQS queue and trigger
the same recovery path.

## See it in action

Clone the required nanochat fork beside this repository and pin the tested
revision:

```bash
git clone --branch iteration/observability --single-branch \
  https://github.com/moca/nanochat.git ../nanochat
git -C ../nanochat checkout --detach \
  a0f52493e96f46071ca35d94b60d95231a5a47ec
```

The release gate rejects a different or dirty nanochat checkout.

Then follow the [demo runbook](docs/DEMO.md) to provision the stack, launch
training, and pull the plug.

## Explore the project

| Start here | What you will find |
|---|---|
| [How it works](docs/HOW-IT-WORKS.md) | The checkpoint, retry, and interruption mechanisms in code |
| [Architecture](docs/ARCHITECTURE.md) | The complete system and recovery path |
| [Demo](docs/DEMO.md) | The end-to-end runbook, including real captured output |
| [Production checklist](docs/PRODUCTION-CHECKLIST.md) | What must change before relying on the demo in production |

## Licensing

Third-party attribution and license texts are recorded in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). This project is licensed
under the Apache License 2.0; see [`LICENSE`](LICENSE). Copyright 2026 Moca
Guero.

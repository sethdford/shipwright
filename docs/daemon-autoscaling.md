# Daemon auto-scaling and fleet worker pool

_Moved from the maintainer's global ~/.claude/CLAUDE.md on 2026-10-13 so it loads only when relevant._

## Auto-Scaling (Daemon)

The daemon can dynamically adjust worker count based on system resources:

```json
{
  "auto_scale": true,
  "auto_scale_interval": 5,
  "max_workers": 8,
  "min_workers": 1,
  "worker_mem_gb": 4,
  "estimated_cost_per_job_usd": 5.0
}
```

Scaling factors (takes the minimum):
- **CPU**: 75% of cores (e.g., 8-core → max 6 workers)
- **Memory**: available GB / `worker_mem_gb`
- **Budget**: remaining daily budget / `estimated_cost_per_job_usd`
- **Queue**: current demand (active + queued issues)

## Fleet Worker Pool

Distribute a total worker budget across repos proportionally to demand:

```json
{
  "worker_pool": {
    "enabled": true,
    "total_workers": 12,
    "rebalance_interval_seconds": 120
  }
}
```

When enabled, the fleet rebalancer runs in the background and redistributes workers every N seconds. Repos with more queued issues get more workers. Each repo always gets at least 1 worker.

## Daemon Configuration

Generate with `shipwright daemon init`, then edit `.claude/daemon-config.json`:

| Field | Default | Purpose |
|-------|---------|---------|
| `max_parallel` | `2` | Static worker limit (overridden by auto_scale) |
| `auto_scale` | `false` | Enable resource-aware dynamic scaling |
| `max_workers` | `8` | Ceiling for auto-scaler |
| `min_workers` | `1` | Floor for auto-scaler |
| `self_optimize` | `false` | Auto-tune based on DORA metrics |
| `auto_template` | `false` | Pick pipeline template by issue complexity |
| `max_retries` | `2` | Retry failed pipelines with escalation |
| `priority_lane` | `false` | Reserve a slot for urgent/hotfix issues |

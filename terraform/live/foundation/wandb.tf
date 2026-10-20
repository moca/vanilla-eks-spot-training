# Here, not in the eks root: a secret there is re-forgotten on every rebuild.
# Only the CONTAINER is Terraform's -- scripts/set-wandb-key.sh writes the value
# out-of-band, so it never passes through state and apply cannot tell you it is
# empty. The eks root discovers it by name.
resource "aws_secretsmanager_secret" "wandb" {
  name        = "${var.cluster_name}/wandb-api-key"
  description = "W&B API key for nanochat training runs"

  # 0, not the 30-day default: otherwise the name stays reserved after a destroy
  # and the next apply fails with InvalidRequestException.
  recovery_window_in_days = 0

  tags = local.tags
}

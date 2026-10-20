output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "karpenter_interruption_queue_url" {
  description = "SQS queue Karpenter polls; scripts/inject-termination.sh writes here"
  value       = module.karpenter.queue_url
}

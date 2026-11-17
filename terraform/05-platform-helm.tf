# 1. ArgoCD (syncs k8s/ manifests from GitHub to EKS)
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  depends_on = [aws_eks_node_group.main]
}

# 2. Argo Rollouts (progressive rollouts + instant rollbacks)
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true

  depends_on = [aws_eks_node_group.main]
}

# 3. Metrics Server (required for HPA to read pod CPU/memory)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"

  depends_on = [aws_eks_node_group.main]
}

# 4. IAM Role for Cluster Autoscaler (IRSA via EKS OIDC)
locals {
  oidc_provider = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.project_name}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${var.project_name}-cluster-autoscaler-policy"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ]
      Resource = "*"
    }]
  })
}

# 5. Cluster Autoscaler (scales EC2 ASG nodes up/down)
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = var.aws_region
    autoDiscovery = {
      clusterName = aws_eks_cluster.main.name
    }
    rbac = {
      serviceAccount = {
        name = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
        }
      }
    }
  })]

  depends_on = [aws_eks_node_group.main, aws_iam_role_policy.cluster_autoscaler]
}

# 6. IAM Policy & Role for AWS Load Balancer Controller (IRSA)
resource "aws_iam_policy" "alb_controller" {
  name   = "${var.project_name}-alb-controller-policy"
  policy = file("${path.module}/alb-iam-policy.json")
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.project_name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# 7. AWS Load Balancer Controller Helm Install
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName = aws_eks_cluster.main.name
    region      = var.aws_region
    vpcId       = aws_vpc.main.id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
      }
    }
  })]

  depends_on = [aws_eks_node_group.main, aws_iam_role_policy_attachment.alb_controller]
}

# 8. Loki (log storage in lightweight single-pod mode, no EBS volume needed)
resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      auth_enabled  = false
      useTestSchema = true
      commonConfig  = { replication_factor = 1 }
      storage       = { type = "filesystem" }
    }
    singleBinary = {
      replicas    = 1
      persistence = { enabled = false }
      extraVolumes = [{
        name     = "loki-data"
        emptyDir = {}
      }]
      extraVolumeMounts = [{
        name      = "loki-data"
        mountPath = "/var/loki"
      }]
    }
    backend      = { replicas = 0 }
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    gateway      = { enabled = false }
  })]

  depends_on = [aws_eks_node_group.main]
}

# 9. Promtail (collects pod logs from every EKS node and sends them to Loki)
resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = "monitoring"

  values = [yamlencode({
    config = {
      clients = [{
        url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
      }]
    }
  })]

  depends_on = [helm_release.loki]
}

# 10. Prometheus + Grafana + Alerting (Loki pre-configured as datasource)
resource "helm_release" "monitoring" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    grafana = {
      additionalDataSources = [{
        name   = "Loki"
        type   = "loki"
        url    = "http://loki.monitoring.svc.cluster.local:3100"
        access = "proxy"
      }]
    }
  })]

  depends_on = [aws_eks_node_group.main]
}

# 11. Create staging & prod namespaces + inject RDS credentials as K8s Secrets
resource "kubernetes_namespace" "app_envs" {
  for_each = toset(["staging", "prod"])

  metadata {
    name = each.key
  }

  depends_on = [aws_eks_node_group.main]
}

resource "kubernetes_secret" "db_secret" {
  for_each = toset(["staging", "prod"])

  metadata {
    name      = "db-secret"
    namespace = kubernetes_namespace.app_envs[each.key].metadata[0].name
  }

  data = {
    DB_HOST     = aws_db_instance.main.address
    DB_PORT     = "3306"
    DB_USER     = aws_db_instance.main.username
    DB_PASSWORD = random_password.db.result
    DB_NAME     = "tododb_${each.key}"
  }
}

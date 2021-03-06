output "kubeconfig" { value = module.eks.kubeconfig }

locals {
  cluster_name    = "k8s-${random_id.cluster.hex}"
  cluster_version = "1.18"
  region          = "us-east-1"
  ingress_gateway_annotations = {
    "controller.service.externalTrafficPolicy"     = "Local",
    "controller.service.type"                      = "NodePort",
    "controller.config.server-tokens"              = "false",
    "controller.config.use-proxy-protocol"         = "false",
    "controller.config.compute-full-forwarded-for" = "true",
    "controller.config.use-forwarded-headers"      = "true",
    "controller.metrics.enabled"                   = "true",
    "controller.autoscaling.maxReplicas"           = "1",
    "controller.autoscaling.minReplicas"           = "1",
    "controller.autoscaling.enabled"               = "true",
    "controller.publishService.enabled"            = "true",
    "serviceAccount.create"                        = "true",
    "rbac.create"                                  = "true"
  }
}
resource "random_id" "cluster" {
  byte_length = 8
}
provider "aws" {
  # We need at least 3.16.0 because it fixes a problem with creating/deleting
  # Fargate profiles in parallel. See this issue for more information:
  # https://github.com/hashicorp/terraform-provider-aws/issues/13372#issuecomment-729689441
  # version = "~> 3.16.0"
  # Using 2.67.0 so that Route53 that was developed using the eks cluster works with the Fargate
  version = "~> 2.67.0"
  region  = local.region
}


module "vpc" {
  source = "github.com/FairwindsOps/terraform-vpc.git?ref=v5.0.1"

  aws_region           = local.region
  az_count             = 2
  aws_azs              = "us-east-1b, us-east-1c"
  single_nat_gateway   = 1
  multi_az_nat_gateway = 0

  enable_s3_vpc_endpoint = "true"

  # Tag subnets for use by AWS' load-balancers and the ALB ingress controllers
  # See https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
  global_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_prod_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # version         = "13.2.1"
  # eks 13.2.1 has dependency for aws provider 3.16.0 so moving eks version to 12.1.0
  version         = "12.1.0"
  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version
  vpc_id          = module.vpc.aws_vpc_id
  subnets         = module.vpc.aws_subnet_private_prod_ids

  # Look ma, no node_groups!
  # node_groups = {
  #   eks_nodes = {
  #     desired_capacity = 3
  #     max_capacity     = 3
  #     min_capacity     = 3
  #     instance_type = "t2.small"
  #   }
  # }
  manage_aws_auth = false
  write_kubeconfig = false
}

data "aws_eks_cluster" "main" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "main" {
  name = module.eks.cluster_id
}

resource "aws_iam_role" "iam_role_fargate" {
  name = "eks-fargate-profile-${local.cluster_name}"
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "AmazonEKSFargatePodExecutionRolePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.iam_role_fargate.name
}

resource "aws_eks_fargate_profile" "default_namespaces" {
  depends_on             = [module.eks]
  cluster_name           = data.aws_eks_cluster.main.name
  fargate_profile_name   = "default-namespaces-${local.cluster_name}"
  pod_execution_role_arn = aws_iam_role.iam_role_fargate.arn
  subnet_ids             = module.vpc.aws_subnet_private_prod_ids
  timeouts {
    # For reasons unknown, Fargate profiles can take upward of 20 minutes to
    # delete! I've never seen them go past 30m, though, so this seems OK.
    delete = "30m"
  }
  selector {
    namespace = "default"
  }
  selector {
    namespace = "kube-system"
  }
}

# Per AWS docs, you have to patch the coredns deployment to remove the
# constraint that it wants to run on ec2, then restart it.
resource "null_resource" "coredns_patch" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = base64encode(module.eks.kubeconfig)
    }
    command     = <<-EOF
      kubectl --kubeconfig <(echo $KUBECONFIG | base64 -d) \
        patch deployment coredns \
        --namespace kube-system \
        --type=json \
        -p='[{"op": "remove", "path": "/spec/template/metadata/annotations", "value": "eks.amazonaws.com/compute-type"}]'
    EOF
  }
}

resource "null_resource" "coredns_restart_on_fargate" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = base64encode(module.eks.kubeconfig)
    }
    # Note the "rollout status" command blocks until the "rollout restart" is
    # complete. We do this intentionally because the cluster basically isn't
    # functional until coredns is operating (for example, helm deployments may
    # timeout).
    command     = <<-EOF
      kubectl --kubeconfig <(echo $KUBECONFIG | base64 -d) rollout restart -n kube-system deployment coredns && \
      kubectl --kubeconfig <(echo $KUBECONFIG | base64 -d) rollout status -n kube-system deployment coredns
    EOF
  }
  depends_on = [
    null_resource.coredns_patch,
    aws_eks_fargate_profile.default_namespaces
  ]
}

# We need an OIDC provider for the ALB ingress controller to work
data "tls_certificate" "main" {
  url = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
}
resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.main.certificates[0].sha1_fingerprint]
  url             = data.aws_eks_cluster.main.identity[0].oidc[0].issuer
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
    load_config_file       = false
    config_path            = "./kubeconfig_${module.eks.cluster_id}"
  }
  # Helm 2.0.1 seems to have issues with alias. When alias is removed the helm_release provider working
  # Using Helm < 2.0.1 version seem to solve the issue.
  version = "~> 1.2"
}

data "aws_region" "current" {}

# Use a convenient module to install the AWS Load Balancer controller
module "aws_load_balancer_controller" {
  source                    = "github.com/GSA/terraform-kubernetes-aws-load-balancer-controller.git?ref=v4.1.0"
  # source                    = "/local/path/to/terraform-kubernetes-aws-load-balancer-controller"
  k8s_cluster_type          = "eks"
  k8s_namespace             = "kube-system"
  aws_region_name           = data.aws_region.current.name
  k8s_cluster_name          = data.aws_eks_cluster.main.name
  alb_controller_depends_on = [aws_eks_fargate_profile.default_namespaces, module.vpc, module.eks.cluster_id]

}


# ---------------------------------------------------------
# Provision the Ingress Controller using Helm
# ---------------------------------------------------------
resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  chart      = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  # version    = "0.5.2"

  namespace       = "kube-system"
  cleanup_on_fail = "true"
  atomic          = "true"
  timeout         = 600

  dynamic "set" {
    for_each = local.ingress_gateway_annotations
    content {
      name  = set.key
      value = set.value
      type  = "string"
    }
  }
  # set {
  #   name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ssl-cert"
  #   value = aws_acm_certificate.cert.id
  # }
  values = [<<-VALUES
    controller: 
      extraArgs: 
        http-port: 8080 
        https-port: 8543 
      containerPort: 
        http: 8080 
        https: 8543 
      service: 
        ports: 
          http: 80 
          https: 443 
        targetPorts: 
          http: 8080 
          https: 8543 
      image: 
        allowPrivilegeEscalation: false
    VALUES
  ]
  # provisioner "local-exec" {
  #   interpreter = ["/bin/bash", "-c"]
  #   environment = {
  #     KUBECONFIG = base64encode(module.eks.kubeconfig)
  #   }
  #   command = "helm --kubeconfig <(echo $KUBECONFIG | base64 -d) test --logs -n ${self.namespace} ${self.name}"
  # }
  set {
    name  = "clusterName"
    value = module.eks.cluster_id
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.aws_vpc_id
  }
  set {
    name  = "aws_iam_role_arn"
    value = module.aws_load_balancer_controller.aws_iam_role_arn
  }
  depends_on = [module.aws_load_balancer_controller]
}

# Give the controller time to react to any recent events (eg an ingress was
# removed and an ALB needs to be deleted) before actually removing it.
resource "time_sleep" "alb_controller_destroy_delay" {
  depends_on = [module.aws_load_balancer_controller]
  destroy_duration = "90s"
}

resource "kubernetes_ingress" "alb_to_nginx" {
  wait_for_load_balancer = true
  metadata {
    name      = "alb-ingress-to-nginx-ingress"
    namespace = "kube-system"

    labels = {
      app = "nginx"
    }

    annotations = {
      "alb.ingress.kubernetes.io/healthcheck-path" = "/"
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
      "kubernetes.io/ingress.class" = "alb"
    }
  }

  spec {
    rule {
      http {
        path {
          path = "/*"
          backend {
            service_name = "ingress-nginx-controller"
            service_port = "80"
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    time_sleep.alb_controller_destroy_delay,
    module.aws_load_balancer_controller
  ]
}

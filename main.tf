provider "aws" {
  version = "2.54"
  region  = var.region

  assume_role {
    role_arn = var.role_arn
  }
}

provider "aws" {
  alias   = "alm"
  version = "2.54"
  region  = var.alm_region

  assume_role {
    role_arn = var.alm_role_arn
  }
}

terraform {
  backend "s3" {
    key     = "andi"
    encrypt = true
  }
}

data "terraform_remote_state" "alm_remote_state" {
  backend   = "s3"
  workspace = var.alm_workspace

  config = {
    bucket   = var.alm_state_bucket_name
    key      = "alm"
    region   = var.alm_region
    role_arn = var.alm_role_arn
  }
}

data "terraform_remote_state" "env_remote_state" {
  backend   = "s3"
  workspace = terraform.workspace

  config = {
    bucket   = var.alm_state_bucket_name
    key      = "operating-system"
    region   = var.alm_region
    role_arn = var.alm_role_arn
  }
}

resource "aws_iam_access_key" "andi" {
  user = data.terraform_remote_state.env_remote_state.outputs.andi_aws_user_name
}

resource "random_string" "andi_lv_salt" {
  length           = 64
  special          = true
  override_special = "/@$#*"
}

resource "local_file" "kubeconfig" {
  filename = "${path.module}/outputs/kubeconfig"
  content  = data.terraform_remote_state.env_remote_state.outputs.eks_cluster_kubeconfig
}

# Consume the actions.redirect and listen ports
resource "local_file" "helm_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}.yaml"

  content = <<EOF
environment: "${terraform.workspace}"
ingress:
  annotations:
    kubernetes.io/ingress.class: "alb"
    alb.ingress.kubernetes.io/ssl-policy: "ELBSecurityPolicy-TLS-1-2-2017-01"
    alb.ingress.kubernetes.io/subnets: "${join(
  ",",
  data.terraform_remote_state.env_remote_state.outputs.public_subnets,
)}"
    alb.ingress.kubernetes.io/security-groups: "${data.terraform_remote_state.env_remote_state.outputs.allow_all_security_group}"
    alb.ingress.kubernetes.io/certificate-arn: "${data.terraform_remote_state.env_remote_state.outputs.tls_certificate_arn},${data.terraform_remote_state.env_remote_state.outputs.root_tls_certificate_arn}"
    alb.ingress.kubernetes.io/healthcheck-path: "/healthcheck"
    alb.ingress.kubernetes.io/tags: scos.delete.on.teardown=true
    alb.ingress.kubernetes.io/actions.redirect: '{"Type": "redirect", "RedirectConfig":{"Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}'
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
  port: 80
postgres:
  host: "${module.andi_rds.address}"
  port: "${module.andi_rds.port}"
  dbname: "${module.andi_rds.name}"
  user: "${module.andi_rds.username}"
  password: "${data.aws_secretsmanager_secret_version.andi_rds_password.secret_string}"
aws:
  accessKeyId: "${aws_iam_access_key.andi.id}"
  accessKeySecret: "${aws_iam_access_key.andi.secret}"
EOF

}

resource "local_file" "public_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}-public.yaml"

  content = <<EOF
ingress:
  annotations:
    alb.ingress.kubernetes.io/scheme: "${var.internet_facing_public_andi ? "internet-facing" : "internal"}"
global:
  ingress:
    rootDnsZone: "${data.terraform_remote_state.env_remote_state.outputs.root_dns_zone_name}"
    dnsZone: "${data.terraform_remote_state.env_remote_state.outputs.internal_dns_zone_name}"
EOF

}

resource "local_file" "private_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}-private.yaml"

  content = <<EOF
ingress:
  annotations:
    alb.ingress.kubernetes.io/scheme: "internal"
global:
  ingress:
    dnsZone: "${data.terraform_remote_state.env_remote_state.outputs.internal_dns_zone_name}"
EOF

}

resource "local_file" "auth0_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}-auth0.yaml"

  content  = <<EOF
  global:
    auth:
      jwt_issuer: "https://${var.auth0_tenant}.auth0.com/"
      auth0_domain: "${var.auth0_tenant}.auth0.com"
  auth:
    auth0_client_id: "${var.auth0_client_id}"
    auth0_client_secret: "${data.aws_secretsmanager_secret_version.andi_auth0_client_secret.secret_string}"
  EOF
}


resource "null_resource" "helm_deploy" {
  provisioner "local-exec" {
    command = <<EOF
set -x

export KUBECONFIG=${local_file.kubeconfig.filename}

export AWS_DEFAULT_REGION=us-east-2

set +x
# checks to see if the secret value already exists in the environment and creates it if it doesnt
kubectl -n admin get secrets -o jsonpath='{.items[*].metadata.name}' | grep andi-lv-salt
[ $? != 0 ] && kubectl -n admin create secret generic andi-lv-salt --from-literal=salt='${random_string.andi_lv_salt.result}' || echo "already exists"
set -x
helm repo add scdp https://urbanos-public.github.io/charts/
helm repo update
helm upgrade --install andi scdp/andi --namespace=admin \
    --values ${local_file.helm_vars.filename} \
    --values ${local_file.private_vars.filename} \
    --values andi.yaml \
    --values ${local_file.auth0_vars.filename} \
      ${var.extra_helm_args}

helm upgrade --install andi-public scdp/andi --namespace=admin \
    --values ${local_file.helm_vars.filename} \
    --values ${local_file.public_vars.filename} \
    --values andi.yaml \
    --values ${local_file.auth0_vars.filename} \
    --values andi-public.yaml \
      ${var.extra_helm_args}
EOF

  }

  triggers = {
    # Triggers a list of values that, when changed, will cause the resource to be recreated
    # ${uuid()} will always be different thus always executing above local-exec
    hack_that_always_forces_null_resources_to_execute = uuid()
  }
}

variable "chartVersion" {
  description = "Version of the chart to deploy"
  default     = "1.8.4"
}

resource "aws_db_parameter_group" "andi" {
  name   = "andi-db-parameter-group"
  family = "postgres10"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

module "andi_rds" {
  source = "git@github.com:SmartColumbusOS/scos-tf-rds?ref=2.0.0"

  vers                     = "10.17"
  prefix                   = "${terraform.workspace}-andi-postgres"
  identifier               = "${terraform.workspace}-andi"
  database_name            = "andi"
  type                     = "postgres"
  attached_vpc_id          = data.terraform_remote_state.env_remote_state.outputs.vpc_id
  attached_subnet_ids      = data.terraform_remote_state.env_remote_state.outputs.private_subnets
  attached_security_groups = [data.terraform_remote_state.env_remote_state.outputs.chatter_sg_id]
  instance_class           = var.postgres_instance_class
  parameter_group_name     = aws_db_parameter_group.andi.id
  delete_automated_backups = "true"
}

data "aws_secretsmanager_secret_version" "andi_rds_password" {
  secret_id = module.andi_rds.password_secret_id
}

data "aws_secretsmanager_secret" "andi_auth0_client_secret_name" {
  name = "${terraform.workspace}-andi-auth0-client-secret"
}

data "aws_secretsmanager_secret_version" "andi_auth0_client_secret" {
  secret_id = data.aws_secretsmanager_secret.andi_auth0_client_secret_name.id
}

variable "region" {
  description = "Region of ALM resources"
  default     = "us-west-2"
}

variable "role_arn" {
  description = "The ARN for the assume role for ALM access"
  default     = "arn:aws:iam::199837183662:role/jenkins_role"
}

variable "alm_role_arn" {
  description = "The ARN for the assume role for ALM access"
  default     = "arn:aws:iam::199837183662:role/jenkins_role"
}

variable "alm_state_bucket_name" {
  description = "The name of the S3 state bucket for ALM"
  default     = "scos-alm-terraform-state"
}

variable "extra_helm_args" {
  description = "Extra command arguments that will be passed to helm upgrade command"
  default     = ""
}

variable "postgres_instance_class" {
  description = "The size of the andi rds instance"
  default     = "db.t3.small"
}

variable "alm_region" {
  description = "Region of ALM resources"
  default     = "us-east-2"
}

variable "alm_workspace" {
  description = "The workspace to pull ALM outputs from"
  default     = "alm"
}

variable "internet_facing_public_andi" {
  description = "Should the public ALBs be internet facing"
  default     = false
}

variable "auth0_tenant" {
  description = "Auth0 tenant name for authentication"
  default     = "smartcolumbusos-demo"
}

variable "auth0_client_id" {
  description = "Auth0 client ID for authentication"
}

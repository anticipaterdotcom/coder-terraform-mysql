terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

variable "repo" {
  description = "The repo of shopware"
  type        = string
  default     = "git@github.com:anticipaterdotcom/shopware6-starter.git"
}

variable "branch" {
  description = "The branch of shopware"
  type        = string
  default     = "main"
}

variable "dump" {
  description = "The database dump of shopware"
  type        = string
  default     = "https://github.com/anticipaterdotcom/shopware6-starter/raw/main/public/demo.sql.gz"
}

variable "upload" {
  description = "The upload folder of shopware"
  type        = string
  default     = "https://github.com/anticipaterdotcom/shopware6-starter/raw/main/public/demo.tgz"
}

variable "env" {
  description = "The env of shopware https://github.com/anticipaterdotcom/shopware6-starter/raw/main/.env.example"
  type        = string
  default     = <<-EOT
  EOT
}

variable "startup_pre_commands" {
  description = "Startup pre commands"
  type        = string
  default     = <<-EOT
  EOT
}

variable "startup_post_commands" {
  description = "Startup post commands"
  type        = string
  default     = <<-EOT
  EOT
}

locals {
  username = "root"
}

variable "is_local" {
  description = "Flag to indicate if terraform is running locally"
  type        = bool
  default     = false
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "shopware" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
}

resource "coder_app" "code-server-shopware" {
  agent_id     = coder_agent.shopware.id
  slug         = "code-server-shopware"
  display_name = "code-server-shopware"
  url          = "http://localhost:13337/?folder=/home/${local.username}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
}

resource "docker_network" "network" {
  name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-network"
}

module "code_server_mysql" {
  source  = "git::https://github.com/anticipaterdotcom/coder-terraform-modules.git//modules/mysql"
  network = docker_network.network.name
}

module "code_server_phpmyadmin" {
  source = "git::https://github.com/anticipaterdotcom/coder-terraform-modules.git//modules/phpmyadmin"
  network = docker_network.network.name
  is_local = var.is_local
}

resource "docker_image" "shopware" {
  name = "dockware/dev:6.6.3.0"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.shopware.name
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  networks_advanced {
    name = docker_network.network.name
  }
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = var.is_local ? ["/bin/bash", "-c", "tail -f /dev/null"] : ["sudo", "su", "-l", "dockware", "-s", "sh", "-c", replace(coder_agent.shopware.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.shopware.token}"]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }

  # Add labels in Docker to keep track of orphan resources.
  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

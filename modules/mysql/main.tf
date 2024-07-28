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

variable "network" {
  description = "The network name"
  type        = string
}

locals {
  username = data.coder_workspace_owner.me.name
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "docker_image" "mysql" {
  name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql"
  build {
    context = "."
  }
  triggers = {
    always_rebuild = timestamp()
  }
}

resource "docker_container" "mysql" {
  image = docker_image.mysql.image_id
  name  = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql"
  networks_advanced {
    name = "${var.network}"
  }
  env = [
    "MYSQL_ROOT_PASSWORD=db",
    "MYSQL_USER=db",
    "MYSQL_PASSWORD=db",
    "MYSQL_DATABASE=db"
  ]
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



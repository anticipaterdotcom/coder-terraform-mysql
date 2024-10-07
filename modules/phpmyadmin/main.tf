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

variable "pma_host" {
  description = "The PMA host"
  type        = string
  default     = "db"
}

variable "pma_user" {
  description = "The PMA user"
  type        = string
  default     = "db"
}

variable "pma_pass" {
  description = "The PMA pass"
  type        = string
  default     = "db"
}

locals {
  username = data.coder_workspace_owner.me.name
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "phpmyadmin" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  order          = 9
  startup_script = <<-EOT
    set -e

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-client

    /docker-entrypoint.sh apache2-foreground >/tmp/phpmyadmin-server.log 2>&1 &

    # Wait for MySQL Container ${var.pma_host} to be ready
    while ! mysqladmin ping -h"${var.pma_host}" --silent; do
        echo "Waiting for MySQL ${var.pma_host} to start..."
        sleep 10
    done

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.19.1
    /tmp/code-server/bin/code-server --auth none --port 13338 >/tmp/code-server.log 2>&1 &
  EOT
}

resource "coder_app" "code-server-phpmyadmin" {
  agent_id     = coder_agent.phpmyadmin.id
  slug         = "code-server-phpmyadmin"
  display_name = "code-server-phpmyadmin"
  url          = "http://localhost:13338/?folder=/home/${local.username}"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13338/healthz"
    interval  = 5
    threshold = 6
  }
}

resource "docker_image" "phpmyadmin" {
  name = "phpmyadmin/phpmyadmin"
}

variable "is_local" {
  description = "Flag to indicate if terraform is running locally"
  type        = bool
  default     = false
}

resource "docker_container" "phpmyadmin" {
  count = data.coder_workspace.me.start_count
  image = docker_image.phpmyadmin.image_id
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-phpmyadmin"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  networks_advanced {
    name = "${var.network}"
  }
  # Use the docker gateway if the access URL is 127.0.0.1
  # Use the docker gateway if the access URL is 127.0.0.1 or dev.anticipater.local
  entrypoint = var.is_local ? ["/bin/bash", "-c", "tail -f /dev/null"] : ["sh", "-c", replace(coder_agent.shopware.init_script, "/localhost|127\\.0\\.0\\.1|dev\\.anticipater\\.local/", "host.docker.internal")]
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.phpmyadmin.token}",
    "PMA_HOST=${var.pma_host}",
    "PMA_USER=${var.pma_user}",
    "PMA_PASSWORD=${var.pma_pass}",
    "APACHE_PORT=8080"
  ]
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

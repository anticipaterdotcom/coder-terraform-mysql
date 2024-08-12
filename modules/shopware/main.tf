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

variable "shopware" {
  description = "Shopware version"
  type        = string
  default     = "6.6.4.1"
}

locals {
  username = "data.coder_workspace_owner.me.name"
  pma_host = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
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
  order          = 1
  startup_script = <<-EOT
    set -e

    ${var.startup_pre_commands}

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      mkdir ~/.ssh
      touch ~/.init_done
    fi

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.19.1
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3

    if [[ "${var.shopware}" == 6.5* ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y python-is-python3
    fi

    if [[ "${var.shopware}" == 6.6* ]]; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y python-is-python3
    fi

    ssh-keyscan -t rsa bitbucket.org >> ~/.ssh/known_hosts
    ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts

    cd /var/www/
    cp /var/www/html/.env /var/www/.env
    rm -rf /var/www/html
    mkdir -p /var/www/html
    mkdir -p temp_dir
    git clone --single-branch --branch ${var.branch} ${var.repo} temp_dir
    mv temp_dir/* /var/www/html
    rm -rf temp_dir --no-preserve-root
    chown www-data:www-data -Rf /var/www/html
    cp /var/www/.env /var/www/html/.env
    mkdir -p /var/www/html/custom/plugins
    mkdir -p /var/www/html/custom/static-plugins

    cd /var/www/html
    composer install --no-interaction --optimize-autoloader --no-suggest --no-scripts
    sed -i 's/idn_to_utf8($request->getHttpHost())/($request->getHttpHost())/g' /var/www/html/vendor/shopware/storefront/Framework/Routing/RequestTransformer.php

    /entrypoint.sh >/tmp/dockware.log 2>&1 &

    # Wait for MySQL  to be ready
    while ! mysqladmin ping --silent; do
        echo "Waiting for MySQL to start..."
        sleep 10
    done

    wget -nv -O dump.sql.gz ${var.dump}
    zcat dump.sql.gz | mysql -u 'root' -proot shopware

    cd /var/www/html
    sed -i 's/http:\/\/localhost/https:\/\/80--shopware--${lower(data.coder_workspace.me.name)}--${lower(data.coder_workspace_owner.me.name)}.cloud.dinited.dev\//g' .env
    echo "SHOPWARE_SKIP_WEBINSTALLER=TRUE" >> /var/www/html/.env
    echo "LOCK_DSN=flock" >> /var/www/html/.env
    python3 -c "import json; print(json.dumps(dict([item.split('=', 1) for item in '${var.env}'.strip('[]').split(',')])))" | jq -r 'keys[] as $k | "\($k)=\(.[$k])"' >> /var/www/html/.env

    # Media files
    cd /tmp && wget -nv -O upload.tgz ${var.upload} && mkdir -p /var/www/html/public/media && cd /var/www/html/public/media && tar xfz /tmp/upload.tgz --warning=no-unknown-keyword

    cd /var/www/html
    rm -rf config/jwt/*
    bin/console system:generate-jwt-secret || true
    bin/console user:create --admin --email=john@doe.com --firstName="John" --lastName="Doe" --password=shopware --no-interaction admin || true
    bin/console user:change-password admin --password shopware || true
    bin/console sales-channel:update:domain 80--shopware--${lower(data.coder_workspace.me.name)}--${lower(data.coder_workspace_owner.me.name)}.cloud.dinited.dev
    ./bin/build-administration.sh || true
    ./bin/build-storefront.sh || true

    chown www-data:www-data -Rf /var/www/html
    # Reverse proxy hack
    sed -i '2i\\$_SERVER["HTTPS"]="on";' /var/www/html/public/index.php

    ${var.startup_post_commands}

  EOT

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace_owner.me.email}"
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = "${data.coder_workspace_owner.me.email}"
  }
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

resource "docker_image" "shopware" {
  name = "dockware/dev:${var.shopware}"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.shopware.name
  user = "root"
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  networks_advanced {
    name = docker_network.network.name
  }
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = var.is_local ? ["/bin/bash", "-c", "tail -f /dev/null"] : ["sh", "-c", replace(coder_agent.shopware.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
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

module "code_server_phpmyadmin" {
  source = "git::https://github.com/anticipaterdotcom/coder-terraform-modules.git//modules/phpmyadmin"
  network = docker_network.network.name
  pma_host = "${local.pma_host}"
  pma_user = "root"
  pma_pass = "root"
  is_local = var.is_local
}

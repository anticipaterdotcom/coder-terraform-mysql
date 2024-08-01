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
  description = "The repo of wordpress"
  type        = string
  default     = "git@github.com:anticipaterdotcom/wordpress-bedrock.git"
}

variable "dump" {
  description = "The database dump of wordpress"
  type        = string
  default     = "https://github.com/anticipaterdotcom/wordpress-bedrock/raw/main/.ddev/db_snapshots/dump.sql.gz"
}

variable "upload" {
  description = "The upload folder of wordpress"
  type        = string
  default     = "https://github.com/anticipaterdotcom/wordpress-bedrock/raw/main/.ddev/file_snapshots/upload.tgz"
}

variable "env" {
  description = "The env of wordpress https://github.com/anticipaterdotcom/wordpress-bedrock/raw/main/.env.example"
  type        = string
  default     = <<-EOT
  EOT
}

locals {
  username = data.coder_workspace_owner.me.name
}


data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "wordpress" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    set -e

    # Prepare user home with default files on first start.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      mkdir ~/.ssh
      touch ~/.init_done
    fi

    echo "${var.env}" > ~/.env

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.19.1
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &

    exit;

    # Update package lists
    apt-get update

    # Install MariaDB Server
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo gnupg git unzip iputils-ping mariadb-client vim net-tools wget curl

    # Add yarn
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list

    # Update package lists
    apt-get update

    # Install yarn
    DEBIAN_FRONTEND=noninteractive apt-get install -y yarn

    # Install NVM
    curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash \
        && export NVM_DIR="$HOME/.nvm" \
        && [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" \
        && nvm install 18 \
        && nvm use 18

    # Memory limit
    echo "memory_limit = 2G" >> /usr/local/etc/php/conf.d/memory-limit.ini

    # Copy the Apache virtual host configuration file
    wget -O /etc/apache2/sites-available/000-default.conf https://github.com/anticipaterdotcom/wordpress-bedrock/raw/main/.ddev/file_snapshots/000-default.conf
    wget -O /var/www/html/index.html https://github.com/anticipaterdotcom/wordpress-bedrock/raw/main/.ddev/file_snapshots/index.html
    wget -O /var/www/html/.env https://github.com/anticipaterdotcom/wordpress-bedrock/raw/main/.env.example
    chown root:root /var/www/html/.env

    docker-php-ext-install pdo pdo_mysql

    # Enable mod_rewrite
    a2enmod rewrite

    # Enable mod_proxy
    a2enmod proxy
    a2enmod proxy_http

    # Enable the site
    a2ensite 000-default

    # Cleanup
    apt-get clean && rm -rf /var/lib/apt/lists/*

    # Install wp-cli
    curl -o /bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /bin/wp-cli.phar
    cd /bin && mv wp-cli.phar wp

    # Install Composer
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    /etc/init.d/apache2 start

    rm -rf /var/www/html/*
    ssh-keyscan -t rsa bitbucket.org >> ~/.ssh/known_hosts
    ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts

    cd /var/www/
    mkdir -p temp_dir
    git clone ${var.repo} temp_dir
    mv temp_dir/* /var/www/html
    rm -rf temp_dir --no-preserve-root
    cd /var/www/html

    # Write the coder-${data.coder_workspace.me.id}-mysql variable to an environment file
    echo "DATABASE_URL='mysql://db:db@coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql:3306/db'" >> /var/www/html/.env
    echo 'WP_HOME="https://80--wordpress--${lower(data.coder_workspace.me.name)}--${lower(data.coder_workspace_owner.me.name)}.cloud.dinited.dev/"' >> /var/www/html/.env
    echo 'WP_SITEURL="https://80--wordpress--${lower(data.coder_workspace.me.name)}--${lower(data.coder_workspace_owner.me.name)}.cloud.dinited.dev/wp"' >> /var/www/html/.env

    # Wait for MySQL Container coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql to be ready
    while ! mysqladmin ping -h"coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql" --silent; do
        echo "Waiting for MySQL coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql to start..."
        sleep 10
    done

    wget -nv -O dump.sql.gz ${var.dump}
    zcat dump.sql.gz | mysql -h coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}-mysql -u 'db' -pdb db

    chown -Rf www-data:www-data /var/www/html
    composer install
    wp user create admin admin@anticipater.com --role=administrator --user_pass=admin --allow-root || true

    # Frontend
    # yarn install
    # node_modules/.bin/webpack --config=node_modules/laravel-mix/setup/webpack.config.js

    # Media files
    cd /tmp && wget -nv -O upload.tgz ${var.upload} && mkdir -p /var/www/html/app/uploads && cd /var/www/html/web/app/uploads && tar xfzv /tmp/upload.tgz

    chown www-data:www-data -R /var/www/html
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

resource "coder_app" "code-server-wordpress" {
  agent_id     = coder_agent.wordpress.id
  slug         = "code-server-wordpress"
  display_name = "code-server-wordpress"
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
}

resource "docker_image" "wordpress" {
  name = "wordpress:php8.0-apache"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.wordpress.name
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  networks_advanced {
    name = docker_network.network.name
  }
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = ["sh", "-c", replace(coder_agent.wordpress.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.wordpress.token}"]
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

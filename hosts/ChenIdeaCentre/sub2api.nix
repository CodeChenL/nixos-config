{ config, pkgs, lib, ... }:

let
  cfg = config.services.sub2api;
  package = pkgs.sub2api;
  port = 8080;
  adminEmail = "chenjiali@radxa.com";
  secretSourceDir = "${config.users.users.chen.home}/nixos-config/secrets/sub2api";
  adminPasswordSourceFile = "${secretSourceDir}/admin-password";
  databasePasswordSourceFile = "${secretSourceDir}/database-password";
  jwtSecretSourceFile = "${secretSourceDir}/jwt-secret";
  redisPasswordSourceFile = "${secretSourceDir}/redis-password";
  secretsDir = "/var/lib/sub2api/secrets";

  # setup script：初始化 secrets 和数据库
  setupScript = pkgs.writeShellScript "sub2api-setup" ''
    set -euo pipefail

    admin_password_source=${lib.escapeShellArg adminPasswordSourceFile}

    # Create secrets directory
    mkdir -p ${secretsDir}
    chmod 700 ${secretsDir}

    if [ ! -s "$admin_password_source" ]; then
      echo "sub2api admin password source file is missing or empty: $admin_password_source" >&2
      exit 1
    fi
    install -m 0600 -o root -g root "$admin_password_source" ${secretsDir}/admin-password

    database_password_source=${lib.escapeShellArg databasePasswordSourceFile}
    jwt_secret_source=${lib.escapeShellArg jwtSecretSourceFile}
    redis_password_source=${lib.escapeShellArg redisPasswordSourceFile}

    # Generate or import secrets
    ensure_secret() {
      source=$1
      target=${secretsDir}/$2
      if [ -n "$source" ]; then
        install -m 0600 -o root -g root "$source" "$target"
      elif [ ! -s "$target" ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > "$target"
        chmod 600 "$target"
      fi
    }
    ensure_secret "$database_password_source" db-password
    ensure_secret "$jwt_secret_source" jwt-secret
    ensure_secret "$redis_password_source" redis-password

    # Read secrets
    ADMIN_PASSWORD=$(tr -d '\r\n' < ${secretsDir}/admin-password)
    DB_PASSWORD=$(cat ${secretsDir}/db-password)
    JWT_SECRET=$(cat ${secretsDir}/jwt-secret)
    REDIS_PASSWORD=$(cat ${secretsDir}/redis-password)

    # Set PostgreSQL password (run as postgres user)
    ${lib.optionalString (!cfg.externalDatabase) ''
      ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/psql -c "ALTER USER sub2api WITH PASSWORD '$DB_PASSWORD';"
    ''}

    # Write environment file for sub2api service
    cat > ${secretsDir}/env << EOF
ADMIN_PASSWORD=$ADMIN_PASSWORD
DATABASE_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
REDIS_PASSWORD=$REDIS_PASSWORD
EOF
    chmod 600 ${secretsDir}/env
  '';

  # systemd service 配置
  sub2apiConfig = {
    Type = "simple";
    User = "sub2api";
    Group = "sub2api";
    ExecStart = "${package}/bin/sub2api";
    WorkingDirectory = "/var/lib/sub2api";
    Restart = "on-failure";
    RestartSec = 5;

    # 安全加固
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ReadWritePaths = [ "/var/lib/sub2api" ];

    # 从 setup script 生成的环境文件加载 DATABASE_PASSWORD
    EnvironmentFile = [ "${secretsDir}/env" ];
  };

  # setup service 配置（只在首次运行）
  setupServiceConfig = {
    Type = "oneshot";
    User = "root";
    Group = "root";
    RemainAfterExit = true;
    ExecStart = setupScript;
  };
in
{
  options.services.sub2api = {
    enable = lib.mkEnableOption "Sub2API AI API Gateway";

    externalDatabase = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use a remote database backend instead of local PostgreSQL/Redis";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables to set";
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL
    services.postgresql = lib.mkIf (!cfg.externalDatabase) {
      enable = true;
      ensureDatabases = [ "sub2api" ];
      ensureUsers = [
        {
          name = "sub2api";
          ensureDBOwnership = true;
        }
      ];
    };

    # Redis
    services.redis.servers."" = lib.mkIf (!cfg.externalDatabase) {
      enable = true;
      port = 6379;
    };

    # Setup service：初始化 secrets 和数据库
    systemd.services.sub2api-setup = {
      description = "Sub2API Setup";
      after = (lib.optional (!cfg.externalDatabase) "postgresql-setup.service");
      requires = (lib.optional (!cfg.externalDatabase) "postgresql-setup.service");
      before = [ "sub2api.service" ];
      serviceConfig = setupServiceConfig;
    };

    # Main service
    systemd.services.sub2api = {
      description = "Sub2API AI API Gateway";
      after = (lib.optional (!cfg.externalDatabase) "postgresql.service")
        ++ lib.optional (!cfg.externalDatabase) "redis.service"
        ++ [ "sub2api-setup.service" ];
      wants = (lib.optional (!cfg.externalDatabase) "postgresql.service")
        ++ lib.optional (!cfg.externalDatabase) "redis.service";
      requires = [ "sub2api-setup.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.openssl ];

      serviceConfig = sub2apiConfig;

      environment = {
        GIN_MODE = "release";
        # AUTO_SETUP 让 sub2api 自动创建 admin 用户和 config.yaml
        AUTO_SETUP = "true";
        ADMIN_EMAIL = adminEmail;
        SERVER_PORT = toString port;
        # DATABASE_* 变量由 sub2api 从环境变量读取
        DATABASE_HOST = "localhost";
        DATABASE_PORT = "5432";
        DATABASE_USER = "sub2api";
        # DATABASE_PASSWORD 从 EnvironmentFile 加载
        DATABASE_DBNAME = "sub2api";
        DATABASE_SSLMODE = "disable";
        REDIS_HOST = "localhost";
        REDIS_PORT = "6379";
        # JWT_SECRET 由 sub2api 自动生成
      } // cfg.environment;
    };

    # Create user and group
    users.users.sub2api = {
      isSystemUser = true;
      group = "sub2api";
      home = "/var/lib/sub2api";
      createHome = true;
    };
    users.groups.sub2api = {};

    # Firewall
    networking.firewall.allowedTCPPorts = [ port ];
  };
}

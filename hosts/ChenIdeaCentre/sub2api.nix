{ config, pkgs, lib, ... }:

let
  cfg = config.services.sub2api;

  # setup script：初始化 secrets 和数据库
  setupScript = pkgs.writeShellScript "sub2api-setup" ''
    set -euo pipefail

    admin_password_source=${lib.escapeShellArg cfg.adminPasswordSourceFile}

    # Create secrets directory
    mkdir -p ${cfg.secretsDir}
    chmod 700 ${cfg.secretsDir}

    if [ ! -s "$admin_password_source" ]; then
      echo "sub2api admin password source file is missing or empty: $admin_password_source" >&2
      exit 1
    fi
    install -m 0600 -o root -g root "$admin_password_source" ${cfg.secretsDir}/admin-password

    # Generate secrets if not exists or empty
    if [ ! -s ${cfg.secretsDir}/db-password ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${cfg.secretsDir}/db-password
      chmod 600 ${cfg.secretsDir}/db-password
    fi

    if [ ! -s ${cfg.secretsDir}/jwt-secret ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${cfg.secretsDir}/jwt-secret
      chmod 600 ${cfg.secretsDir}/jwt-secret
    fi

    # Read secrets
    ADMIN_PASSWORD=$(tr -d '\r\n' < ${cfg.secretsDir}/admin-password)
    DB_PASSWORD=$(cat ${cfg.secretsDir}/db-password)
    JWT_SECRET=$(cat ${cfg.secretsDir}/jwt-secret)

    # Set PostgreSQL password (run as postgres user)
    ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/psql -c "ALTER USER sub2api WITH PASSWORD '$DB_PASSWORD';" || true

    # Write environment file for sub2api service
    cat > ${cfg.secretsDir}/env << EOF
ADMIN_PASSWORD=$ADMIN_PASSWORD
DATABASE_PASSWORD=$DB_PASSWORD
JWT_SECRET=$JWT_SECRET
EOF
    chmod 600 ${cfg.secretsDir}/env
  '';

  # systemd service 配置
  sub2apiConfig = {
    Type = "simple";
    User = "sub2api";
    Group = "sub2api";
    ExecStart = "${cfg.package}/bin/sub2api";
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
    EnvironmentFile = [ "${cfg.secretsDir}/env" ];
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

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sub2api;
      description = "Sub2API package to use";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port to listen on";
    };

    adminEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@sub2api.local";
      description = "Admin email for initial setup (used by sub2api's AUTO_SETUP)";
    };

    adminPasswordSourceFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Runtime source file containing the initial admin password";
    };

    secretsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sub2api/secrets";
      description = "Directory containing generated secrets (db-password, jwt-secret)";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables to set";
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL
    services.postgresql = {
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
    services.redis.servers."" = {
      enable = true;
      port = 6379;
    };

    # Setup service：初始化 secrets 和数据库
    systemd.services.sub2api-setup = {
      description = "Sub2API Setup";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
      before = [ "sub2api.service" ];
      serviceConfig = setupServiceConfig;
    };

    # Main service
    systemd.services.sub2api = {
      description = "Sub2API AI API Gateway";
      after = [ "postgresql.service" "redis.service" "sub2api-setup.service" ];
      wants = [ "postgresql.service" "redis.service" "sub2api-setup.service" ];
      wantedBy = [ "multi-user.target" ];

      path = [ pkgs.openssl ];

      serviceConfig = sub2apiConfig;

      environment = {
        GIN_MODE = "release";
        # AUTO_SETUP 让 sub2api 自动创建 admin 用户和 config.yaml
        AUTO_SETUP = "true";
        ADMIN_EMAIL = cfg.adminEmail;
        SERVER_PORT = toString cfg.port;
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
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}

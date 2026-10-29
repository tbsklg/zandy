{ name, host, headers, addHeaders ? { }, secrets ? { } }: pkgs:
let
  inherit (pkgs) lib;
  config = pkgs.writeText "${name}-gateway.json" (builtins.toJSON {
    admin.disabled = true;
    logging.logs.default.level = "ERROR";
    apps.http.servers.gateway = {
      listen = [ "127.0.0.1:{env.ZANDY_GATEWAY_PORT}" ];
      automatic_https.disable = true;
      routes = [{
        handle = [{
          handler = "reverse_proxy";
          upstreams = [{ dial = "${host}:443"; }];
          transport = { protocol = "http"; tls = { }; };
          headers.request = {
            set = { Host = [ host ]; } // headers;
            add = addHeaders;
            delete = lib.subtractLists (builtins.attrNames headers) [ "Authorization" "X-Api-Key" ];
          };
        }];
      }];
    };
  });
  envfile = lib.concatMapStrings (secret: "${secret}={secret.${secret}}\n") (builtins.attrNames secrets);
in
{
  inherit name secrets;
  files = lib.optionalAttrs (secrets != { }) { "secrets.env" = envfile; };
  argv = [ "${pkgs.caddy}/bin/caddy" "run" "--config" "${config}" ]
    ++ lib.optionals (secrets != { }) [ "--envfile" "{dir}/secrets.env" ];
}

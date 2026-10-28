{ name, host, headers }: pkgs:
let
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
            delete = pkgs.lib.subtractLists (builtins.attrNames headers) [ "Authorization" "X-Api-Key" ];
          };
        }];
      }];
    };
  });
in
{
  inherit name;
  argv = [ "${pkgs.caddy}/bin/caddy" "run" "--config" "${config}" ];
}

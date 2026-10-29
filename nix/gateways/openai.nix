{ env ? "OPENAI_API_KEY", host ? "api.openai.com" }:
import ./caddy.nix {
  name = "openai";
  inherit host;
  headers.Authorization = [ "Bearer {env.${env}}" ];
}
